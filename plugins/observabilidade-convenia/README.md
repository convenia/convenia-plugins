# observabilidade-convenia

Detector de projeto do painel de uso de agentes. No início de cada sessão e a cada uso de skill, ele manda ao Grafana um evento pequeno com o ID da sessão, o **nome** do projeto (nunca o caminho da pasta) e o e-mail da conta.

- Não imprime nada, então não gasta token.
- Não atrasa o Claude Code: o envio é feito em segundo plano.
- Lê o endereço e a chave do Grafana da configuração central da organização (`~/.claude/remote-settings.json`). Sem essa configuração, não faz nada.
- **Mac e Linux:** usa `bash`, `jq` e `curl`.
- **Windows:** precisa do Git for Windows (Git Bash). O script repassa para a versão em PowerShell.

Os arquivos em `scripts/` são cópias geradas por `estudo-grafana/admin/montar_loja.sh`. Não edite aqui.
