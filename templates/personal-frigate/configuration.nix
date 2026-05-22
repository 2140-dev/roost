{
  config,
  lib,
  pkgs,
  ...
}:

# Personal Frigate deployment. Frigate + bitcoind + electrs all run on
# this single host, with Frigate's plaintext Electrum listener bound to
# loopback by default for a Sparrow wallet running on the same machine.
#
# Disk: electrs's mainnet index is roughly 80+ GB on top of bitcoind's
# own chainstate and (with txindex) ~700+ GB of block + index data.
# Size the data partition accordingly before the first sync.

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

  # === Scenario A: single-box (default) ===
  # Frigate + bitcoind + electrs all live on this host. Sparrow runs on
  # the same machine and connects to 127.0.0.1:50001. Nothing Electrum-
  # related is exposed on the network.
  services.personal-frigate = {
    enable = true;
    # listenAddress = "127.0.0.1";  # default
    # port = 50001;                 # default
  };

  # === Scenario B: home node + remote Sparrow ===
  # This box hosts the Bitcoin + Frigate stack; Sparrow runs on a
  # different machine on your LAN/VPN. Bind Frigate's plaintext Electrum
  # listener to the LAN/VPN IP and open the port. Prefer a private
  # transport (WireGuard / Tailscale) for this — v1 has no TLS, so treat
  # the listener as you would any other plaintext service. Setting
  # `host = config.networking.hostName` makes the wallet UI show this
  # machine's hostname instead of `localhost`.
  #
  # services.personal-frigate = {
  #   enable = true;
  #   listenAddress = "10.0.0.5";       # FIXME: this host's LAN/VPN IP
  #   # port = 50001;                   # default
  #   host = config.networking.hostName;
  # };
  # networking.firewall.allowedTCPPorts = [ 22 50001 ];
}
