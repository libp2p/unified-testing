using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Linq;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Multiformats.Address;
using Nethermind.Libp2p;
using Nethermind.Libp2p.Core;
using Libp2p.Protocols.KadDht;
using Libp2p.Protocols.KadDht.Integration;
using StackExchange.Redis;

namespace DotnetNode;

class Program
{
    static async Task Main(string[] args)
    {
        var role = Environment.GetEnvironmentVariable("ROLE");
        var redisAddr = Environment.GetEnvironmentVariable("REDIS_ADDR");
        var testKey = Environment.GetEnvironmentVariable("TEST_KEY");

        if (string.IsNullOrEmpty(role) || string.IsNullOrEmpty(redisAddr) || string.IsNullOrEmpty(testKey))
        {
            Console.WriteLine("error: Missing required environment variables");
            return;
        }

        var redisConn = await ConnectionMultiplexer.ConnectAsync(redisAddr);
        var db = redisConn.GetDatabase();

        var containerIp = GetLocalIpAddress(redisAddr);
        var listenAddrs = new[] { Multiaddress.Decode($"/ip4/{containerIp}/tcp/0") };

        var services = new ServiceCollection();
        using var loggerFactory = LoggerFactory.Create(builder => builder.SetMinimumLevel(LogLevel.Information).AddConsole());
        services.AddSingleton<ILoggerFactory>(loggerFactory);
        var logger = loggerFactory.CreateLogger<Program>();

        services.AddKadDht(options =>
        {
            options.Mode = role == "querier" ? KadDhtMode.Client : KadDhtMode.Server;
            options.OperationTimeout = TimeSpan.FromSeconds(30);
        });
        
        services.AddLibp2p(builder => builder.WithKadDht());

        var identity = new Identity();
        services.AddSingleton<ILocalPeer>(sp => sp.GetRequiredService<IPeerFactory>().Create(identity));

        var serviceProvider = services.BuildServiceProvider();

        var localPeer = serviceProvider.GetRequiredService<ILocalPeer>();
        var kadProtocol = serviceProvider.GetRequiredService<KadDhtProtocol>();
        var sharedState = serviceProvider.GetRequiredService<SharedDhtState>();

        // Auto-add inbound peers to routing table
        localPeer.OnConnected += session =>
        {
            var remotePeerId = session.RemoteAddress?.GetPeerId();
            if (remotePeerId is not null)
            {
                kadProtocol.AddNode(new DhtNode
                {
                    PeerId = remotePeerId,
                    PublicKey = new Libp2p.Protocols.KadDht.Kademlia.PublicKey(remotePeerId.Bytes.ToArray()),
                    Multiaddrs = session.RemoteAddress is not null ? [session.RemoteAddress.ToString()] : Array.Empty<string>()
                });
            }
            return Task.CompletedTask;
        };

        var cts = new CancellationTokenSource();
        await localPeer.StartListenAsync(listenAddrs, cts.Token);
        
        // Background maintenance
        _ = Task.Run(() => kadProtocol.RunAsync(cts.Token), cts.Token);

        // Get actual port
        var port = localPeer.ListenAddresses.First().Protocols.First(p => p.Name == "tcp").Value;
        var myMultiaddr = $"/ip4/{containerIp}/tcp/{port}/p2p/{localPeer.Identity.PeerId}";
        logger.LogInformation("Node started at {Multiaddr}", myMultiaddr);

        if (role == "bootstrap")
        {
            await db.StringSetAsync($"{testKey}_bootstrap_addr", myMultiaddr);
            await kadProtocol.BootstrapAsync(cts.Token);
            await Task.Delay(Timeout.Infinite, cts.Token);
        }
        else if (role == "provider")
        {
            string bootstrapAddr = null;
            while (string.IsNullOrEmpty(bootstrapAddr))
            {
                bootstrapAddr = await db.StringGetAsync($"{testKey}_bootstrap_addr");
                if (string.IsNullOrEmpty(bootstrapAddr)) await Task.Delay(500);
            }

            var ma = Multiaddress.Decode(bootstrapAddr);
            await localPeer.DialAsync(ma, cts.Token);
            
            var remotePeerId = ma.GetPeerId();
            kadProtocol.AddNode(new DhtNode
            {
                PeerId = remotePeerId,
                PublicKey = new Libp2p.Protocols.KadDht.Kademlia.PublicKey(remotePeerId.Bytes.ToArray()),
                Multiaddrs = [ bootstrapAddr ]
            });
            await Task.Delay(1000, cts.Token);
            await kadProtocol.BootstrapAsync(cts.Token);

            try
            {
                var keyBytes = Encoding.UTF8.GetBytes($"interop-test-key-{testKey}");
                await kadProtocol.ProvideAsync(keyBytes, cts.Token);
                logger.LogInformation("Test 1 -> Success");
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Test 1 FAILED: Could not announce provider");
                Console.WriteLine($"error: Test 1 FAILED: Could not announce provider: {ex.Message}");
            }

            try
            {
                var keyBytes = Encoding.UTF8.GetBytes($"/example/data/{testKey}");
                var valueBytes = Encoding.UTF8.GetBytes("hello from dotnet client");
                await kadProtocol.PutValueAsync(keyBytes, valueBytes, cts.Token);
                logger.LogInformation("Test 3 -> Success");
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Test 3 FAILED: Could not put value");
                Console.WriteLine($"error: Test 3 FAILED: Could not put value: {ex.Message}");
            }

            await db.StringSetAsync($"{testKey}_provider_done", "done");
            await Task.Delay(Timeout.Infinite, cts.Token);
        }
        else if (role == "querier")
        {
            // Overall 90-second timeout for the entire querier operation.
            // Without this, FindProvidersAsync/GetValueAsync can hang for minutes
            // exhausting the routing table in a tiny 3-node network.
            using var querierTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            using var querierCts = CancellationTokenSource.CreateLinkedTokenSource(cts.Token, querierTimeout.Token);

            try
            {
                string bootstrapAddr = null;
                while (string.IsNullOrEmpty(bootstrapAddr))
                {
                    bootstrapAddr = await db.StringGetAsync($"{testKey}_bootstrap_addr");
                    if (string.IsNullOrEmpty(bootstrapAddr)) await Task.Delay(500, querierCts.Token);
                }

                string providerDone = null;
                while (string.IsNullOrEmpty(providerDone))
                {
                    providerDone = await db.StringGetAsync($"{testKey}_provider_done");
                    if (string.IsNullOrEmpty(providerDone)) await Task.Delay(500, querierCts.Token);
                }

                var ma = Multiaddress.Decode(bootstrapAddr);
                await localPeer.DialAsync(ma, querierCts.Token);

                var remotePeerId = ma.GetPeerId();
                kadProtocol.AddNode(new DhtNode
                {
                    PeerId = remotePeerId,
                    PublicKey = new Libp2p.Protocols.KadDht.Kademlia.PublicKey(remotePeerId.Bytes.ToArray()),
                    Multiaddrs = [ bootstrapAddr ]
                });
                await Task.Delay(1000, querierCts.Token); // Give routing table time to process AddNode
                await kadProtocol.BootstrapAsync(querierCts.Token);

                bool foundProviders = false;
                for (int attempt = 0; attempt < 10 && !foundProviders && !querierCts.Token.IsCancellationRequested; attempt++)
                {
                    try
                    {
                        using var callTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                        using var callCts = CancellationTokenSource.CreateLinkedTokenSource(querierCts.Token, callTimeout.Token);
                        var keyBytes = Encoding.UTF8.GetBytes($"interop-test-key-{testKey}");
                        var provs = await kadProtocol.FindProvidersAsync(keyBytes, 1, callCts.Token);
                        if (provs != null && provs.Any())
                        {
                            foundProviders = true;
                            logger.LogInformation("Test 2 -> Success");
                        }
                    }
                    catch (OperationCanceledException) when (!querierCts.Token.IsCancellationRequested) { }
                    catch (Exception ex) 
                    { 
                        logger.LogWarning(ex, "Attempt {Attempt} failed", attempt + 1); 
                    }

                    if (!foundProviders)
                        await Task.Delay(1000, querierCts.Token).ConfigureAwait(false);
                }

                if (!foundProviders)
                {
                    logger.LogError("Test 2 FAILED: No providers found after 10 attempts");
                    Console.WriteLine("error: Test 2 FAILED: No providers found after 10 attempts");
                }

                bool foundValue = false;
                for (int attempt = 0; attempt < 10 && !foundValue && !querierCts.Token.IsCancellationRequested; attempt++)
                {
                    try
                    {
                        using var callTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                        using var callCts = CancellationTokenSource.CreateLinkedTokenSource(querierCts.Token, callTimeout.Token);
                        var keyBytes = Encoding.UTF8.GetBytes($"/example/data/{testKey}");
                        var valBytes = await kadProtocol.GetValueAsync(keyBytes, callCts.Token);
                        if (valBytes != null && valBytes.Length > 0)
                        {
                            var strVal = Encoding.UTF8.GetString(valBytes);
                            if (strVal.Contains("hello from"))
                            {
                                foundValue = true;
                                logger.LogInformation("Test 4 -> Success (value: '{Value}')", strVal);
                            }
                        }
                    }
                    catch (OperationCanceledException) when (!querierCts.Token.IsCancellationRequested) { }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Attempt {Attempt} failed", attempt + 1);
                    }

                    if (!foundValue)
                        await Task.Delay(1000, querierCts.Token).ConfigureAwait(false);
                }

                if (!foundValue)
                {
                    logger.LogError("Test 4 FAILED: Value not found after 10 attempts");
                    Console.WriteLine("error: Test 4 FAILED: Value not found after 10 attempts");
                }

                if (foundProviders && foundValue)
                {
                    Console.WriteLine("status: pass");
                }
                else
                {
                    Console.WriteLine("status: fail");
                    Environment.Exit(1);
                }
            }
            catch (OperationCanceledException) when (querierTimeout.Token.IsCancellationRequested)
            {
                Console.WriteLine("error: Querier timed out after 90 seconds (DHT lookup hung)");
                Console.WriteLine("status: fail");
                Environment.Exit(1);
            }
        }
    }

    private static string StripPeerId(string maddr)
    {
        var idx = maddr.IndexOf("/p2p/");
        return idx > 0 ? maddr.Substring(0, idx) : maddr;
    }

    private static string GetLocalIpAddress(string redisAddr)
    {
        var parts = redisAddr.Split(':');
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, 0);
        socket.Connect(parts[0], int.Parse(parts[1]));
        return (socket.LocalEndPoint as IPEndPoint)?.Address.ToString() ?? "127.0.0.1";
    }
}
