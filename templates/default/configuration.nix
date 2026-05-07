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

  services.public-frigate = {
    enable = true;

    # FIXME: public DNS name for this server. The DNS record must point at
    # this host before deploy, since ACME will request a certificate for it.
    host = "frigate.example.com";

    # FIXME: email for Let's Encrypt registration. Replace with manual
    # tls.certificateFile / tls.keyFile if you manage TLS out of band.
    tls.acmeEmail = "ops@example.com";
  };
}
