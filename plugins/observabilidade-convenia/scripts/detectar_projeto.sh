#!/bin/bash
# Detector de projeto: hook do Claude Code (SessionStart e PostToolUse de Skill).
# Descobre em que projeto a pessoa está e manda um evento pequeno ao Grafana,
# com o mesmo ID de sessão da telemetria nativa. Assim o painel cruza uso x projeto
# mesmo em pastas que a própria pessoa criou.
#
# Regras de segurança (testadas em testes_detector.sh):
#  - NUNCA imprime nada: saída de hook de início de sessão vira contexto e gastaria token.
#  - Sempre sai com 0 e nunca espera a rede: o envio vai em segundo plano, com limite de 3 s.
#  - Manda só o NOME do projeto, nunca o caminho (o caminho tem o usuário da máquina).
#
# De onde vêm endpoint e cabeçalho: o Claude Code tira as variáveis OTEL_* do ambiente
# dos hooks (documentado; visto em teste em 04/11/2026). Então o detector lê os arquivos,
# na mesma ordem de prioridade do Claude Code (a configuração central vence):
#  1. ~/.claude/remote-settings.json        configuração central da organização (console)
#  2. managed-settings.json do sistema      MDM/TI (Mac e Linux)
#  3. ~/.claude/settings.json               configuração da própria pessoa
#  DETECTOR_SETTINGS  troca essa lista (arquivos separados por ":"), usado nos testes
#  DETECTOR_CONTA     arquivo da conta do Claude Code, de onde vem o e-mail (padrão: ~/.claude.json)

exec >/dev/null 2>&1   # garante o silêncio, mesmo se algum comando abaixo reclamar

# Windows com Git Bash: repassa para a versão em PowerShell, que não depende do jq.
# No modo embutido (detector dentro da configuração central), a versão PowerShell vem
# na mesma linha de comando; aqui só sai, sem ler a entrada, para ela usar.
# DETECTOR_SO e DETECTOR_POWERSHELL existem só para os testes simularem o Windows no Mac.
# No Windows, cada processo que o bash abre custa de 0,1 a 0,2 s. Por isso este trecho usa só
# recursos do próprio bash ($OSTYPE, cortes de texto, read) e abre um único processo: o
# PowerShell, em segundo plano. Medido no Windows do Bernardo em 05/11/2026: 1.0.1 levava
# 1,5 a 1,8 s; sem os processos extras (uname, dirname, cat, subshell) cai para ~0,4 s.
case "${DETECTOR_SO:-$OSTYPE}" in
  msys*|cygwin*|MINGW*|MSYS*|CYGWIN*)
    [ -n "${DETECTOR_EMBUTIDO:-}" ] && exit 0
    # Pasta do script, sem dirname. O Claude Code chama "C:\...\<versão>/scripts/detectar_projeto.sh".
    barra_inv='\'
    pasta="${0%/*}"
    [ "$pasta" = "$0" ] && pasta="${0%"$barra_inv"*}"
    [ "$pasta" = "$0" ] && pasta=.
    ps1="$pasta/detectar_projeto.ps1"
    [ -f "$ps1" ] || exit 0
    # O PowerShell leva de 1 a 7 s para abrir: lê a entrada aqui (read não abre processo) e
    # entrega ao PowerShell em segundo plano. O hook termina sem esperar por ele.
    IFS= read -r -d '' entrada || true
    "${DETECTOR_POWERSHELL:-powershell.exe}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File "$ps1" <<< "$entrada" >/dev/null 2>&1 &
    exit 0 ;;
esac

command -v jq >/dev/null || exit 0
command -v curl >/dev/null || exit 0

entrada="$(cat)"
CONTA="${DETECTOR_CONTA:-$HOME/.claude.json}"
CANDIDATOS="${DETECTOR_SETTINGS:-$HOME/.claude/remote-settings.json:/Library/Application Support/ClaudeCode/managed-settings.json:/etc/claude-code/managed-settings.json:$HOME/.claude/settings.json}"

endpoint=""; cabecalho=""
IFS=':' read -r -a arquivos <<< "$CANDIDATOS"
for arq in "${arquivos[@]}"; do
  [ -f "$arq" ] || continue
  e="$(jq -r '.env.OTEL_EXPORTER_OTLP_ENDPOINT // empty' "$arq" 2>/dev/null)"
  c="$(jq -r '.env.OTEL_EXPORTER_OTLP_HEADERS // empty' "$arq" 2>/dev/null)"
  if [ -n "$e" ] && [ -n "$c" ]; then endpoint="$e"; cabecalho="$c"; break; fi
done
[ -n "$endpoint" ] && [ -n "$cabecalho" ] || exit 0

evento="$(printf '%s' "$entrada" | jq -r '.hook_event_name // empty')"
sessao="$(printf '%s' "$entrada" | jq -r '.session_id // empty')"
skill="$(printf '%s' "$entrada" | jq -r '.tool_input.skill // empty')"
pasta="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$entrada" | jq -r '.cwd // empty')}"
[ -n "$sessao" ] && [ -n "$pasta" ] || exit 0

slug() {  # mesma regra do marcar_projeto.sh
  # Se o iconv não souber transliterar (ex.: Linux Alpine), segue com o texto original.
  local t; t="$(printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || true)"
  [ -n "$t" ] || t="$1"
  printf '%s' "$t" | sed -E "s/[~'^\`\"]//g" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Nome do projeto, nesta ordem: marca explícita da pasta > repositório git > nome da pasta.
projeto=""; origem=""
marca="$(jq -r '.env.OTEL_RESOURCE_ATTRIBUTES // empty' "$pasta/.claude/settings.json" 2>/dev/null \
         | tr ',' '\n' | sed -n 's/^projeto=//p' | head -1)"
if [ -n "$marca" ]; then
  projeto="$marca"; origem="marca"
elif raiz="$(git -C "$pasta" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$raiz" ]; then
  projeto="$(slug "$(basename "$raiz")")"; origem="git"
else
  projeto="$(slug "$(basename "$pasta")")"; origem="pasta"
fi
# Pasta pessoal (~) ou raiz: o nome seria o usuário da máquina ou vazio.
case "$pasta" in "$HOME"|"$HOME/"|/) projeto="pasta-pessoal"; origem="pasta" ;; esac
[ -n "$projeto" ] || projeto="sem-nome"

email="$(jq -r '.oauthAccount.emailAddress // empty' "$CONTA" 2>/dev/null)"
[ -n "$email" ] || email="$(git config user.email 2>/dev/null)"

case "$evento" in
  SessionStart) nome="sessao_projeto" ;;
  PostToolUse)  [ -n "$skill" ] || exit 0; nome="skill_projeto" ;;
  *) exit 0 ;;
esac

corpo="$(jq -nc --arg ts "$(date +%s)000000000" --arg nome "$nome" --arg sessao "$sessao" \
  --arg projeto "$projeto" --arg origem "$origem" --arg email "$email" --arg skill "$skill" '
  def a(k; v): {key: k, value: {stringValue: v}};
  {resourceLogs: [{
     resource: {attributes: [a("service.name"; "claude-code-projetos")]},
     scopeLogs: [{scope: {name: "observabilidade-convenia.detector", version: "1"},
       logRecords: [{timeUnixNano: $ts, body: {stringValue: $nome},
         attributes: ([a("event.name"; $nome), a("session.id"; $sessao), a("projeto"; $projeto),
                       a("origem_projeto"; $origem), a("user.email"; $email)]
                      + (if $skill != "" then [a("skill.name"; $skill)] else [] end))}]}]}]}')" || exit 0

# Envio em segundo plano: o Claude Code não espera a rede.
( curl -s -o /dev/null --max-time 3 -X POST "${endpoint%/}/v1/logs" \
    -H "Authorization: ${cabecalho#Authorization=}" -H "Content-Type: application/json" \
    -d "$corpo" & )
exit 0
