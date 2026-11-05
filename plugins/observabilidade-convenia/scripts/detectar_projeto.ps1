# Detector de projeto (Windows). Mesmo comportamento do detectar_projeto.sh do Mac/Linux.
# Hook do Claude Code (SessionStart, PostToolUse de Skill, UserPromptExpansion e SubagentStart):
# descobre o projeto e manda um evento pequeno ao Grafana com o mesmo ID de sessão da
# telemetria nativa. Os eventos e atributos estão descritos no topo do detectar_projeto.sh.
#
# Regras: nunca imprime nada (saída de hook de início de sessão vira contexto e gastaria
# token); sempre sai com 0; o envio vai num processo separado e escondido, com limite de 3 s;
# manda só o NOME do projeto, nunca o caminho.
#
# Compatível com Windows PowerShell 5.1 (o que já vem no Windows 10 e 11).

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

try {
    # O Claude Code manda o JSON em UTF-8; sem isto, acentos do nome da pasta chegam trocados.
    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $entrada = [Console]::In.ReadToEnd() | ConvertFrom-Json

    # O Claude Code tira as variáveis OTEL_* do ambiente dos hooks: o detector lê os arquivos,
    # na mesma ordem de prioridade do Claude Code (a configuração central vence).
    $candidatos = if ($env:DETECTOR_SETTINGS) { $env:DETECTOR_SETTINGS -split ';' } else { @(
        (Join-Path $env:USERPROFILE '.claude\remote-settings.json'),   # configuração central da organização
        'C:\Program Files\ClaudeCode\managed-settings.json',           # MDM/TI
        (Join-Path $env:USERPROFILE '.claude\settings.json')            # configuração da própria pessoa
    ) }
    $contaPath = if ($env:DETECTOR_CONTA) { $env:DETECTOR_CONTA } else { Join-Path $env:USERPROFILE '.claude.json' }

    $endpoint = $null; $cabecalho = $null
    foreach ($arq in $candidatos) {
        if (-not (Test-Path -LiteralPath $arq)) { continue }
        try { $s = [IO.File]::ReadAllText($arq) | ConvertFrom-Json } catch { continue }
        if ($s.env.OTEL_EXPORTER_OTLP_ENDPOINT -and $s.env.OTEL_EXPORTER_OTLP_HEADERS) {
            $endpoint = $s.env.OTEL_EXPORTER_OTLP_ENDPOINT; $cabecalho = $s.env.OTEL_EXPORTER_OTLP_HEADERS; break
        }
    }
    if (-not $endpoint -or -not $cabecalho) { exit 0 }

    $evento = $entrada.hook_event_name
    $sessao = $entrada.session_id
    $pasta = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { $entrada.cwd }
    if (-not $sessao -or -not $pasta) { exit 0 }

    # Que evento mandar. Só nomes: nunca o texto do pedido nem os argumentos do comando.
    $skill = ''; $acionamento = ''; $fonte = ''; $agente = ''
    switch ($evento) {
        'SessionStart' { $nome = 'sessao_projeto' }
        'PostToolUse' {            # o Claude escolheu usar uma skill (ferramenta Skill)
            $skill = [string]$entrada.tool_input.skill
            if (-not $skill) { exit 0 }; $nome = 'skill_projeto'; $acionamento = 'modelo'
        }
        'UserPromptExpansion' {    # a pessoa digitou /comando (skill, comando ou skill de plugin)
            $skill = [string]$entrada.command_name; $fonte = [string]$entrada.command_source
            if (-not $skill) { exit 0 }; $nome = 'skill_projeto'; $acionamento = 'digitado'
        }
        'SubagentStart' {          # um subagente começou (Explore, agente da pasta, plugin:agente...)
            $agente = [string]$entrada.agent_type
            if (-not $agente) { exit 0 }; $nome = 'subagente_projeto'
        }
        default { exit 0 }
    }

    function Slug([string]$texto) {
        $decomposto = $texto.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object Text.StringBuilder
        foreach ($c in $decomposto.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($c)
            }
        }
        return (($sb.ToString().ToLowerInvariant()) -replace '[^a-z0-9]+', '-').Trim('-')
    }

    # Nome do projeto, nesta ordem: marca explícita da pasta > repositório git > nome da pasta.
    $projeto = ''; $origem = ''
    $marcaArq = Join-Path $pasta '.claude\settings.json'
    if (Test-Path -LiteralPath $marcaArq) {
        $marca = ([IO.File]::ReadAllText($marcaArq) | ConvertFrom-Json).env.OTEL_RESOURCE_ATTRIBUTES
        if ($marca) {
            foreach ($parte in ($marca -split ',')) {
                if ($parte -like 'projeto=*') { $projeto = $parte.Substring(8); $origem = 'marca'; break }
            }
        }
    }
    $temGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not $projeto -and $temGit) {
        $raiz = git -C "$pasta" rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $raiz) { $projeto = Slug (Split-Path -Leaf $raiz); $origem = 'git' }
    }
    if (-not $projeto) { $projeto = Slug (Split-Path -Leaf $pasta); $origem = 'pasta' }
    # Pasta pessoal ou raiz do disco: o nome seria o usuário da máquina ou vazio.
    $semBarra = $pasta.TrimEnd('\', '/')
    if ($semBarra -eq $env:USERPROFILE.TrimEnd('\') -or $semBarra -match '^[A-Za-z]:$') { $projeto = 'pasta-pessoal'; $origem = 'pasta' }
    if (-not $projeto) { $projeto = 'sem-nome' }

    $email = ''
    if (Test-Path -LiteralPath $contaPath) { $email = ([IO.File]::ReadAllText($contaPath) | ConvertFrom-Json).oauthAccount.emailAddress }
    if (-not $email -and $temGit) { $email = git config user.email 2>$null }
    if (-not $email) { $email = '' }

    function Atributo($k, $v) { @{ key = $k; value = @{ stringValue = [string]$v } } }
    $atributos = New-Object System.Collections.ArrayList
    foreach ($par in @(@('event.name', $nome), @('session.id', $sessao), @('projeto', $projeto),
                       @('origem_projeto', $origem), @('user.email', $email))) {
        [void]$atributos.Add((Atributo $par[0] $par[1]))
    }
    foreach ($par in @(@('skill.name', $skill), @('skill.acionamento', $acionamento),
                       @('skill.fonte', $fonte), @('agent.name', $agente))) {
        if ($par[1]) { [void]$atributos.Add((Atributo $par[0] $par[1])) }
    }

    $ts = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).ToString() + '000000000'
    $corpo = @{
        resourceLogs = @(@{
            resource  = @{ attributes = @((Atributo 'service.name' 'claude-code-projetos')) }
            scopeLogs = @(@{
                scope      = @{ name = 'observabilidade-convenia.detector'; version = '1' }
                logRecords = @(@{ timeUnixNano = $ts; body = @{ stringValue = $nome }; attributes = $atributos.ToArray() })
            })
        })
    }
    $json = ConvertTo-Json -InputObject $corpo -Depth 12 -Compress

    # Envio num processo separado e escondido: o Claude Code não espera a rede.
    $uri = $endpoint.TrimEnd('/') + '/v1/logs'
    $auth = $cabecalho -replace '^Authorization=', ''
    $corpoB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $envio = "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " +
             "`$b = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$corpoB64')); " +
             "Invoke-WebRequest -UseBasicParsing -Method Post -Uri '$uri' -Headers @{ Authorization = '$auth' } " +
             "-ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes(`$b)) -TimeoutSec 3 | Out-Null } catch { }"
    $codificado = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($envio))
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $codificado) | Out-Null
} catch { }
exit 0
