FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy project file and dynamically-cloned dotnet-libp2p source
COPY DotnetNode.csproj .
COPY dotnet-libp2p/ dotnet-libp2p/

# Copy Nethermind's build configuration to root
COPY dotnet-libp2p/global.json dotnet-libp2p/Directory.Build.props ./

RUN dotnet restore

COPY Program.cs .
RUN dotnet publish -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .

ENTRYPOINT ["dotnet", "DotnetNode.dll"]
