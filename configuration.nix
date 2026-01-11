{ config, pkgs, lib, modulesPath, ... }:

let
  # authentik forward auth configuration
  # NOTE: Apps are pointed to authentik-proxy-cloud-01, not the embedded outpost
  # as one might assume due to the Traefik router rule at:
  # https://git.sdko.net/s.git/tree/infra/cluster/cloud-01/authentik-proxy-cloud-01/docker-compose.yml#n24
  authentikOutpost = "https://sso.sdko.net/outpost.goauthentik.io";

  forwardAuthConfig = ''
    auth_request        /outpost.goauthentik.io/auth/nginx;
    error_page          401 = @goauthentik_proxy_signin;
    auth_request_set    $auth_cookie $upstream_http_set_cookie;
    add_header          Set-Cookie $auth_cookie;

    # Translate headers from the outpost back to the upstream
    auth_request_set $authentik_username $upstream_http_x_authentik_username;
    auth_request_set $authentik_groups $upstream_http_x_authentik_groups;
    auth_request_set $authentik_entitlements $upstream_http_x_authentik_entitlements;
    auth_request_set $authentik_email $upstream_http_x_authentik_email;
    auth_request_set $authentik_name $upstream_http_x_authentik_name;
    auth_request_set $authentik_uid $upstream_http_x_authentik_uid;

    proxy_set_header X-authentik-username $authentik_username;
    proxy_set_header X-authentik-groups $authentik_groups;
    proxy_set_header X-authentik-entitlements $authentik_entitlements;
    proxy_set_header X-authentik-email $authentik_email;
    proxy_set_header X-authentik-name $authentik_name;
    proxy_set_header X-authentik-uid $authentik_uid;
  '';

  # Shared authentik locations for each vhost
  authentikLocations = {
    # All requests to /outpost.goauthentik.io must be accessible without authentication
    "/outpost.goauthentik.io" = {
      proxyPass = authentikOutpost;
      extraConfig = ''
        proxy_ssl_verify              off;
        proxy_set_header              Host sso.sdko.net;
        proxy_set_header              X-Forwarded-Host $host;
        proxy_set_header              X-Original-URL $scheme://$http_host$request_uri;
        add_header                    Set-Cookie $auth_cookie;
        auth_request_set              $auth_cookie $upstream_http_set_cookie;
        proxy_pass_request_body       off;
        proxy_set_header              Content-Length "";
      '';
    };

    # When the /auth endpoint returns 401, redirect to /start to initiate SSO
    "@goauthentik_proxy_signin" = {
      extraConfig = ''
        internal;
        add_header Set-Cookie $auth_cookie;
        return 302 /outpost.goauthentik.io/start?rd=$scheme://$http_host$request_uri;
      '';
    };
  };

  # Common SSL config
  sslConfig = {
    forceSSL = true;
    sslCertificate = "/etc/ssl/nodeexporter-timemachine-svc.sdko.net/fullchain.cer";
    sslCertificateKey = "/etc/ssl/nodeexporter-timemachine-svc.sdko.net/key.pem";
    extraConfig = ''
      proxy_buffers 8 16k;
      proxy_buffer_size 32k;
    '';
  };
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub.enable = true;
  boot.initrd.kernelModules = [ "dm-snapshot" ];

  environment.systemPackages = with pkgs; [
    vim
    htop
    ghostty.terminfo
  ];

  services.tailscale.enable = true;

  networking.hostName = "timemachine";
  time.timeZone = "UTC";

  # Users
  users.users = {
    root = {
      hashedPassword = "$6$L3/5BO/M0YfGSKrt$TLbqESpa.ShaCzovng03RjNA97Pk4DIS.p7u0gIvbnGbsQHnsbD2DoNMhz4ePm.3PPbaaK2eiDgxsbjKRuyEG/";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPkyXI1VJ7hDm2AA+ta5yKOTdqjFBfNWKUuhUKuGrMri"
      ];
    };

    # Time Machine backup user for Samba authentication
    # Post-install: smbpasswd -a timemachinedominic
    timemachinedominic = {
      isNormalUser = true;
      home = "/var/lib/timemachine";
      createHome = false;
      group = "timemachine";
      hashedPassword = "$6$QRnJTSlP//QWvMg2$tAzUCxAxkd44LMcq1YGX2AMjpBYMQaFsUgu3Vo87BRng11HxiW9NdhHW4w9e9MhSjhfSnQbMCcvCuv0M4G7Tg.";
    };
  };

  users.groups.timemachine = {};

  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Prometheus node exporter
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    listenAddress = "127.0.0.1";
    enabledCollectors = [
      "systemd"
      "processes"
    ];
  };

  # nginx
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = false;
    serverTokens = false;
    package = pkgs.nginxMainline.override {
      modules = [ pkgs.nginxModules.moreheaders ];
    };

    commonHttpConfig = ''
      more_set_headers "Server: SDKO Timemachine Server";
      more_set_headers "Via: 1.1 sws-gateway";
    '';

    virtualHosts."nodeexporter-timemachine-svc.sdko.net" = sslConfig // {
      locations = authentikLocations // {
        "/" = {
          proxyPass = "http://127.0.0.1:9100";
          extraConfig = forwardAuthConfig + ''
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };
  };

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 445 ];
    allowedUDPPorts = [ 137 138 ];
  };

  # Avahi for Time Machine discovery
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
    extraServiceFiles = {
      timemachine = ''
        <?xml version="1.0" standalone='no'?>
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">%h</name>
          <service>
            <type>_smb._tcp</type>
            <port>445</port>
          </service>
          <service>
            <type>_device-info._tcp</type>
            <port>0</port>
            <txt-record>model=TimeCapsule8,119</txt-record>
          </service>
          <service>
            <type>_adisk._tcp</type>
            <port>445</port>
            <txt-record>sys=waMa=0,adVF=0x100</txt-record>
            <txt-record>dk0=adVN=TimeMachine,adVF=0x82</txt-record>
          </service>
        </service-group>
      '';
    };
  };

  # Samba Time Machine
  services.samba = {
    enable = true;
    openFirewall = false;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "Time Machine Backup Server";
        "server role" = "standalone server";
        "security" = "user";
        "map to guest" = "never";
        "guest ok" = "no";
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072";
        "use sendfile" = "yes";
        "aio read size" = "16384";
        "aio write size" = "16384";
        "min protocol" = "SMB2";
        "ea support" = "yes";
        "vfs objects" = "fruit streams_xattr";
        "fruit:aapl" = "yes";
        "fruit:metadata" = "stream";
        "fruit:model" = "TimeCapsule8,119";
        "fruit:posix_rename" = "yes";
        "fruit:veto_appledouble" = "no";
        "fruit:nfs_aces" = "no";
        "fruit:wipe_intentionally_left_blank_rfork" = "yes";
        "fruit:delete_empty_adfiles" = "yes";
        "logging" = "systemd";
        "log level" = "1";
      };

      "TimeMachine" = {
        "path" = "/var/lib/timemachine";
        "valid users" = "timemachinedominic";
        "writable" = "yes";
        "browseable" = "yes";
        "fruit:time machine" = "yes";
        "fruit:time machine max size" = "600G";
        "create mask" = "0600";
        "directory mask" = "0700";
        "force user" = "timemachinedominic";
        "force group" = "timemachine";
      };
    };
  };

  # Backup directory and SSL certs
  systemd.tmpfiles.rules = [
    "d /var/lib/timemachine 0750 timemachinedominic timemachine -"
    "d /etc/ssl/nodeexporter-timemachine-svc.sdko.net 0750 root nginx -"
  ];

  system.stateVersion = "24.11";
}
