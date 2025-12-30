{ config, pkgs, lib, modulesPath, ... }:

{
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

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 445 ];
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

  # Backup directory
  systemd.tmpfiles.rules = [
    "d /var/lib/timemachine 0750 timemachinedominic timemachine -"
  ];

  system.stateVersion = "24.11";
}
