# observabilidade-convenia

Detector de projeto do painel de uso de agentes. Ele manda ao Grafana um evento pequeno com o ID da sessão, o **nome** do projeto (nunca o caminho da pasta) e o e-mail da conta nestes momentos:

| Momento | Evento | Atributos a mais |
|---|---|---|
| Início da sessão | `sessao_projeto` | — |
| O Claude usa uma skill | `skill_projeto` | `skill.name`, `skill.acionamento=modelo` |
| A pessoa digita `/comando` (skill, comando ou skill de plugin) | `skill_projeto` | `skill.name`, `skill.acionamento=digitado`, `skill.fonte` (`projectSettings`, `userSettings`, `plugin`…) |
| Um subagente começa | `subagente_projeto` | `agent.name` (ex.: `Explore`, `agente-da-pasta`, `plugin:agente`) |

Nunca manda o texto do pedido nem os argumentos do comando, só nomes. No Grafana (Loki), os pontos viram `_`: `skill_name`, `skill_acionamento`, `skill_fonte`, `agent_name`.

- Não imprime nada, então não gasta token.
- Não atrasa o Claude Code: o envio é feito em segundo plano.
- Lê o endereço e a chave do Grafana da configuração central da organização (`~/.claude/remote-settings.json`). Sem essa configuração, não faz nada.
- **Mac e Linux:** usa `bash`, `jq` e `curl`.
- **Windows:** precisa do Git for Windows (Git Bash). O script repassa para a versão em PowerShell.

Os arquivos em `scripts/` são cópias geradas por `estudo-grafana/admin/montar_loja.sh`. Não edite aqui.

## Versões

As versões 1.0.2 e 1.0.3 foram editadas direto neste repositório e ainda não estão no `montar_loja.sh`. Leve as duas para lá antes de gerar a próxima versão.

- **1.0.3**: passa a registrar os dois usos que a 1.0.2 não via. Testado no Claude Code 2.1.317/318, Windows, em 05/11/2026.
  - **`/comando` digitado pela pessoa** (hook `UserPromptExpansion`). Quando a pessoa digita `/skill`, o Claude Code expande o comando direto, sem passar pela ferramenta Skill. Por isso o `PostToolUse` de Skill não disparava. Agora vira `skill_projeto` com `skill.acionamento=digitado` e `skill.fonte`.
  - **Subagentes** (hook `SubagentStart`): vira `subagente_projeto` com `agent.name`. A telemetria nativa já traz `agent_name` nas métricas de tokens e custo. O evento junta o projeto e mostra o nome real dos agentes de plugin. Nas skills, a telemetria nativa troca o nome de plugin por `custom_skill`/`third-party`. Nos agentes, não confirmei.
  - `skill_projeto` vindo do `PostToolUse` ganha `skill.acionamento=modelo`.
  - Os dois scripts passam a decidir o evento antes de procurar o projeto, então hooks sem nada a mandar saem mais cedo.
- **1.0.2**:
  - `hooks.json`: os dois hooks têm `"async": true`. O Claude Code passa o hook para segundo plano e não espera por ele, em qualquer sistema. No Windows do Bernardo, a 1.0.1 ainda segurava o início da sessão por 1,5–9 s e chegou a estourar o limite de 10 s. Com `async`, o hook vai para segundo plano em 0,2–0,4 s, e os eventos continuaram chegando (4 de 4 sessões, 05/11/2026).
  - `detectar_projeto.sh`, no Windows: não abre mais `uname`, `dirname`, `cat` nem subshell, só o PowerShell em segundo plano. Gasta menos processos e não muda nada no Mac e no Linux.
  - `.gitattributes` na raiz: o `.sh` chega com fim de linha Unix (LF) também no Windows, onde o git costuma converter para CRLF.
- **1.0.1**: no Windows, o PowerShell passou a rodar em segundo plano (o hook levava 5,5–5,9 s).
- **1.0.0**: primeira versão.
