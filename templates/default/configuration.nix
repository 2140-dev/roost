{
  config,
  lib,
  pkgs,
  ...
}:

{
  # FIXME: hostname for this machine.
  networking.hostName = "frigate-host";

  # FIXME: pin once at install. Controls migration semantics for stateful
  # services across NixOS releases. Never bump after initial deploy.
  system.stateVersion = "25.11";

  # FIXME: paste your SSH public key.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... your-key-here"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  services.bitcoind = {
    enable = true;
    txindex = true;
    listen = true;
    address = "0.0.0.0";
    dataDirReadableByGroup = true;
  };

  services.electrs.enable = true;

  services.frigate = {
    enable = true;

    # FIXME: public DNS name for this server. Advertised in the Electrum
    # `server.features` response so wallets can verify the endpoint.
    host = "frigate.example.com";

    bitcoind = {
      authType = "COOKIE";
      cookieDir = "/var/lib/bitcoind";
    };
  };

  # frigate reads bitcoind's cookie via group access.
  users.users.frigate.extraGroups = [ "bitcoin" ];

  systemd.services.frigate.after = [
    "bitcoind.service"
    "electrs.service"
  ];
  systemd.services.frigate.wants = [
    "bitcoind.service"
    "electrs.service"
  ];

  # P2P inbound. RPC stays local-only.
  networking.firewall.allowedTCPPorts = [ 8333 ];
}
