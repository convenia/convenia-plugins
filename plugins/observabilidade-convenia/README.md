# observabilidade-convenia

Detector de projeto do painel de uso de agentes. No início de cada sessão e a cada uso de skill, ele manda ao Grafana um evento pequeno com o ID da sessão, o **nome** do projeto (nunca o caminho da pasta) e o e-mail da conta.

- Não imprime nada, então não gasta token.
- Não atrasa o Claude Code: o envio é feito em segundo plano.
- Lê o endereço e a chave do Grafana da configuração central da organização (`~/.claude/remote-settings.json`). Sem essa configuração, não faz nada.
- **Mac e Linux:** usa `bash`, `jq` e `curl`.
- **Windows:** precisa do Git for Windows (Git Bash). O script repassa para a versão em PowerShell.

Os arquivos em `scripts/` são cópias geradas por `estudo-grafana/admin/montar_loja.sh`. Não edite aqui.

## Versões

- **1.0.2** (editada direto neste repositório, ainda não está no `montar_loja.sh`; leve para lá antes de gerar a próxima versão):
  - `hooks.json`: os dois hooks têm `"async": true`. O Claude Code passa o hook para segundo plano e não espera por ele, em qualquer sistema. No Windows do Bernardo, a 1.0.1 ainda segurava o início da sessão por 1,5–9 s e chegou a estourar o limite de 10 s. Com `async`, o hook vai para segundo plano em 0,2–0,4 s, e os eventos continuaram chegando (4 de 4 sessões, 05/11/2026).
  - `detectar_projeto.sh`, no Windows: não abre mais `uname`, `dirname`, `cat` nem subshell, só o PowerShell em segundo plano. Gasta menos processos e não muda nada no Mac e no Linux.
  - `.gitattributes` na raiz: o `.sh` chega com fim de linha Unix (LF) também no Windows, onde o git costuma converter para CRLF.
- **1.0.1**: no Windows, o PowerShell passou a rodar em segundo plano (o hook levava 5,5–5,9 s).
- **1.0.0**: primeira versão.
