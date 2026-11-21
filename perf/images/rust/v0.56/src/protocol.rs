// libp2p perf protocol implementation
// Based on: https://github.com/libp2p/specs/blob/master/perf/perf.md

use libp2p::StreamProtocol;

// Protocol constants
pub const PERF_PROTOCOL: StreamProtocol = StreamProtocol::new("/perf/1.0.0");
pub const BLOCK_SIZE: usize = 64 * 1024; // 64KB blocks

// Perf protocol request
#[derive(Debug, Clone)]
pub struct PerfRequest {
    pub send_bytes: u64, // Bytes client will send to server
    pub recv_bytes: u64, // Bytes client wants to receive from server
}

// Perf protocol response
#[derive(Debug, Clone)]
pub struct PerfResponse {
    pub bytes_sent: u64, // Bytes server sent back
}

// Perf protocol codec
#[derive(Debug, Clone, Default)]
pub struct PerfCodec;

#[async_trait::async_trait]
impl libp2p::request_response::Codec for PerfCodec {
    type Protocol = StreamProtocol;
    type Request = PerfRequest;
    type Response = PerfResponse;

    async fn read_request<T>(
        &mut self,
        _protocol: &Self::Protocol,
        io: &mut T,
    ) -> std::io::Result<Self::Request>
    where
        T: futures::AsyncRead + Unpin + Send,
    {
        use futures::AsyncReadExt;

        let mut buf = [0u8; 8];

        // Read how many bytes the client wants to receive.
        io.read_exact(&mut buf).await?;
        let recv_bytes = u64::from_be_bytes(buf);

        // The upload ends at the client's write-half-close, not at a declared size.
        let mut send_bytes = 0u64;
        let mut read_buf = vec![0u8; BLOCK_SIZE];

        loop {
            let n = io.read(&mut read_buf).await?;
            if n == 0 {
                break;
            }
            send_bytes += n as u64;
        }

        Ok(PerfRequest {
            send_bytes,
            recv_bytes,
        })
    }

    async fn read_response<T>(
        &mut self,
        _protocol: &Self::Protocol,
        io: &mut T,
    ) -> std::io::Result<Self::Response>
    where
        T: futures::AsyncRead + Unpin + Send,
    {
        use futures::AsyncReadExt;

        // Read data from server
        let mut total = 0u64;
        let mut buf = vec![0u8; BLOCK_SIZE];

        loop {
            match io.read(&mut buf).await? {
                0 => break, // EOF
                n => total += n as u64,
            }
        }

        Ok(PerfResponse { bytes_sent: total })
    }

    async fn write_request<T>(
        &mut self,
        _protocol: &Self::Protocol,
        io: &mut T,
        req: Self::Request,
    ) -> std::io::Result<()>
    where
        T: futures::AsyncWrite + Unpin + Send,
    {
        use futures::AsyncWriteExt;

        // Send the requested download size as one big-endian u64.
        io.write_all(&req.recv_bytes.to_be_bytes()).await?;

        // Send our data
        let mut sent = 0u64;
        let block = vec![0u8; BLOCK_SIZE];

        while sent < req.send_bytes {
            let to_send = std::cmp::min(req.send_bytes - sent, BLOCK_SIZE as u64);
            io.write_all(&block[..to_send as usize]).await?;
            sent += to_send;
        }

        io.flush().await?;
        Ok(())
    }

    async fn write_response<T>(
        &mut self,
        _protocol: &Self::Protocol,
        io: &mut T,
        res: Self::Response,
    ) -> std::io::Result<()>
    where
        T: futures::AsyncWrite + Unpin + Send,
    {
        use futures::AsyncWriteExt;

        // Send the requested bytes back
        let mut sent = 0u64;
        let block = vec![0u8; BLOCK_SIZE];

        while sent < res.bytes_sent {
            let to_send = std::cmp::min(res.bytes_sent - sent, BLOCK_SIZE as u64);
            io.write_all(&block[..to_send as usize]).await?;
            sent += to_send;
        }

        io.flush().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::{io::Cursor, AsyncRead, FutureExt};
    use libp2p::request_response::Codec;
    use std::{
        pin::Pin,
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
        task::{Context, Poll},
    };

    struct PausedEof {
        input: Cursor<Vec<u8>>,
        closed: Arc<AtomicBool>,
    }

    impl AsyncRead for PausedEof {
        fn poll_read(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut [u8],
        ) -> Poll<std::io::Result<usize>> {
            let this = self.get_mut();
            match Pin::new(&mut this.input).poll_read(cx, buf) {
                Poll::Ready(Ok(0)) if !this.closed.load(Ordering::SeqCst) => Poll::Pending,
                result => result,
            }
        }
    }

    #[tokio::test]
    async fn request_uses_one_download_length_followed_by_upload() {
        let mut io = Cursor::new(Vec::new());
        PerfCodec
            .write_request(
                &PERF_PROTOCOL,
                &mut io,
                PerfRequest {
                    send_bytes: 3,
                    recv_bytes: 5,
                },
            )
            .await
            .unwrap();

        assert_eq!(
            io.into_inner(),
            [5u64.to_be_bytes().as_slice(), &[0, 0, 0]].concat()
        );
    }

    #[tokio::test]
    async fn server_drains_upload_through_eof() {
        let upload = vec![0xAB; BLOCK_SIZE + 3];
        let mut wire = 7u64.to_be_bytes().to_vec();
        wire.extend_from_slice(&upload);

        let request = PerfCodec
            .read_request(&PERF_PROTOCOL, &mut Cursor::new(wire))
            .await
            .unwrap();

        assert_eq!(request.recv_bytes, 7);
        assert_eq!(request.send_bytes, upload.len() as u64);
    }

    #[tokio::test]
    async fn server_waits_for_upload_half_close() {
        let mut wire = 3u64.to_be_bytes().to_vec();
        wire.extend_from_slice(&7u64.to_be_bytes());
        wire.extend_from_slice(&[1, 2, 3]);
        let closed = Arc::new(AtomicBool::new(false));
        let mut io = PausedEof {
            input: Cursor::new(wire),
            closed: closed.clone(),
        };
        let mut codec = PerfCodec;
        let protocol = PERF_PROTOCOL;
        let mut read = Box::pin(codec.read_request(&protocol, &mut io));

        assert!(read.as_mut().now_or_never().is_none());
        closed.store(true, Ordering::SeqCst);
        let request = read.await.unwrap();
        assert_eq!(request.recv_bytes, 3);
        assert_eq!(request.send_bytes, 11);
    }

    #[tokio::test]
    async fn server_accepts_empty_upload_and_maximum_download_length() {
        let request = PerfCodec
            .read_request(&PERF_PROTOCOL, &mut Cursor::new(u64::MAX.to_be_bytes()))
            .await
            .unwrap();

        assert_eq!(request.recv_bytes, u64::MAX);
        assert_eq!(request.send_bytes, 0);
    }

    #[tokio::test]
    async fn client_counts_response_bytes() {
        let response = PerfCodec
            .read_response(&PERF_PROTOCOL, &mut Cursor::new([0xAB; 3]))
            .await
            .unwrap();

        assert_eq!(response.bytes_sent, 3);
    }

    #[tokio::test]
    async fn server_sends_exact_requested_length() {
        for length in [0, 1, BLOCK_SIZE as u64 + 3] {
            let mut io = Cursor::new(Vec::new());
            PerfCodec
                .write_response(&PERF_PROTOCOL, &mut io, PerfResponse { bytes_sent: length })
                .await
                .unwrap();
            assert_eq!(io.into_inner(), vec![0; length as usize]);
        }
    }
}
