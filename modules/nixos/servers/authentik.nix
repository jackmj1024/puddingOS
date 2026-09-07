{
    config,
    lib,
    pkgs,
    inputs ? {},
    ...
}:
with lib; {
    imports = optional (inputs ? authentik-nix) inputs.authentik-nix.nixosModules.default;

    options.pos.servers.authentik = {
        enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable Authentik identity and access management server.";
        };

        domain = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Public domain to serve Authentik on. Enables nginx and ACME when set.";
        };

        host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            description = "Host Authentik listens on.";
        };

        port = mkOption {
            type = types.port;
            default = 9000;
            description = "Port Authentik listens on.";
        };

        secretKey = mkOption {
            type = types.str;
            description = "Authentik secret key used for signing cookies and tokens.";
        };

        packages = mkOption {
            type = types.nullOr (types.attrsOf types.package);
            default = null;
            description = ''
                The authentik packages provided by authentik-nix.
                Add authentik-nix as a flake input and set:
                pos.servers.authentik.packages = authentik-nix.packages.''${system};
            '';
        };

        ldapOutpost = {
            enable = mkOption {
                type = types.bool;
                default = false;
                description = "Run a native LDAP outpost binding local Authentik users/groups to an LDAP interface, for services that only support LDAP or DAV-style Basic auth.";
            };

            token = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "API token generated from the LDAP outpost's deployment info in the Authentik admin UI.";
            };

            host = mkOption {
                type = types.str;
                default = "127.0.0.1";
                description = "Address the LDAP outpost's LDAP, LDAPS, and metrics listeners bind to.";
            };

            port = mkOption {
                type = types.port;
                default = 3389;
                description = "Port the LDAP outpost's plain LDAP listener binds to.";
            };

            ldapsPort = mkOption {
                type = types.port;
                default = 6636;
                description = "Port the LDAP outpost's LDAPS listener binds to.";
            };

            metricsPort = mkOption {
                type = types.port;
                default = 9310;
                description = "Port the LDAP outpost's Prometheus metrics listener binds to.";
            };
        };
    };
    config = mkMerge [
        (mkIf (config.pos.servers.authentik.domain != null) {
            pos.servers._nginx = true;
        })
        (mkIf (config.pos.enable && config.pos.servers.authentik.enable) {
            assertions = [
                {
                    assertion = (inputs ? authentik-nix) && config.pos.servers.authentik.packages != null;
                    message = ''
                        pos.servers.authentik requires packages to be set.
                        On flakes, add authentik-nix as a flake input and set:
                        pos.servers.authentik.packages = authentik-nix.packages.''${pkgs.system};
                        On non-flakes, import authentik-nix's NixOS module yourself and set
                        pos.servers.authentik.packages manually.
                    '';
                }
            ];
        })
        (optionalAttrs (inputs ? authentik-nix) (mkIf (config.pos.enable && config.pos.servers.authentik.enable && config.pos.servers.authentik.packages != null) {
            services.authentik = {
                enable = true;
                authentikComponents = config.pos.servers.authentik.packages;
                settings = {
                    secret_key = config.pos.servers.authentik.secretKey;
                    disable_startup_analytics = true;
                    avatars = "initials";
                    listen.listen_http = "${config.pos.servers.authentik.host}:${toString config.pos.servers.authentik.port}";
                };
            };
        }))
        (mkIf (config.pos.enable && config.pos.servers.authentik.enable && config.pos.servers.authentik.domain != null) {
            services.nginx.virtualHosts.${config.pos.servers.authentik.domain} = {
                enableACME = true;
                forceSSL = true;
                extraConfig = ''
                    proxy_set_header Host "${config.pos.servers.authentik.domain}";
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                    proxy_set_header X-Forwarded-Host $host;
                    proxy_buffer_size 128k;
                    proxy_buffers 4 256k;
                    proxy_busy_buffers_size 256k;
                '';
                locations."/" = {
                    proxyPass = "http://${config.pos.servers.authentik.host}:${toString config.pos.servers.authentik.port}";
                    proxyWebsockets = true;
                };
            };
        })
        (mkIf (config.pos.enable && config.pos.servers.authentik.enable && config.pos.servers.authentik.ldapOutpost.enable) {
            assertions = [
                {
                    assertion = config.pos.servers.authentik.ldapOutpost.token != null;
                    message = "pos.servers.authentik.ldapOutpost requires token to be set from the LDAP outpost's deployment info in the Authentik admin UI.";
                }
                {
                    assertion = config.pos.servers.authentik.packages != null && config.pos.servers.authentik.packages ? gopkgs;
                    message = "pos.servers.authentik.ldapOutpost requires pos.servers.authentik.packages to include a gopkgs attribute (from authentik-nix.packages.\${system}).";
                }
            ];

            systemd.services.authentik-ldap-outpost = {
                description = "Authentik LDAP outpost";
                after = ["authentik-server.service" "network.target"];
                wants = ["authentik-server.service"];
                wantedBy = ["multi-user.target"];
                environment = {
                    AUTHENTIK_HOST = "http://${config.pos.servers.authentik.host}:${toString config.pos.servers.authentik.port}";
                    AUTHENTIK_INSECURE = "true";
                    AUTHENTIK_LISTEN__LDAP = "${config.pos.servers.authentik.ldapOutpost.host}:${toString config.pos.servers.authentik.ldapOutpost.port}";
                    AUTHENTIK_LISTEN__LDAPS = "${config.pos.servers.authentik.ldapOutpost.host}:${toString config.pos.servers.authentik.ldapOutpost.ldapsPort}";
                    AUTHENTIK_LISTEN__METRICS = "${config.pos.servers.authentik.ldapOutpost.host}:${toString config.pos.servers.authentik.ldapOutpost.metricsPort}";
                };
                serviceConfig = {
                    ExecStart = "${config.pos.servers.authentik.packages.gopkgs.ldap}/bin/ldap";
                    EnvironmentFile = toString (pkgs.writeText "authentik-ldap-outpost-token" "AUTHENTIK_TOKEN=${config.pos.servers.authentik.ldapOutpost.token}");
                    DynamicUser = true;
                    Restart = "on-failure";
                    RestartSec = 5;
                };
            };
        })
    ];
}
