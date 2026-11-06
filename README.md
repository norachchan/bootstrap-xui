# bootstrap-xui

Quick 3x-ui install: SSL (Let's Encrypt IP shortlived / domain) + Reality template inbound.

```bash
bash <(curl -Ls "https://raw.githubusercontent.com/norachchan/bootstrap-xui/main/bootstrap-xui.sh?$(date +%s)")
```

- Default SSL: Let's Encrypt for public IP (`shortlived`, ~6 days, auto-renew via acme.sh). Needs port **80** open. Override: `SSL_MODE=domain SSL_DOMAIN=example.com`.
- Inbound tag: lowercase letters only (`netherlands`), digits/symbols stripped. Non-interactive: `INBOUND_TAG=netherlands`.
- Template Reality SNI/dest: `travel.yandex.ru`
- Credentials printed once → also `/etc/x-ui/install-result.env`
