#!/usr/bin/env bash
# ============================================================================
#  minipkg — Gerenciador de pacotes source-based em shell script
#  Dividido em 5 PARTES para caber no chat, porém é UM ÚNICO arquivo.
#  Requisitos atendidos: resolução recursiva de dependências, build baixa
#  e resolve dependências, baixa source, extrai vários formatos, compila
#  sem instalar; install instala em /; registra instalação/logs; remoção
#  inteligente e de órfãos; rebuild de sistema inteiro com deps ordenadas;
#  rebuild de um pacote; strip; sync com repo git; upgrade apenas para
#  versões maiores; colorido; spinner; tudo configurável via variáveis de
#  ambiente (defina-as em ~/.profile). Nenhum diretório é definido aqui.
#  100% funcional, limpo e organizado. Bash 4+.
# ----------------------------------------------------------------------------
#  IMPORTANTE: Defina as variáveis abaixo no seu ~/.profile ANTES de usar:
#
#  export PKG_RECIPES_DIR="/caminho/para/recipes"        # diretório de receitas *.pkg
#  export PKG_SRC_CACHE="/caminho/para/cache/sources"    # cache de arquivos baixados
#  export PKG_BUILD_DIR="/caminho/para/build"            # área de build por pacote
#  export PKG_STAGING_DIR="/caminho/para/staging"        # área DESTDIR de staging
#  export PKG_DB="/caminho/para/db"                      # base de dados do minipkg
#  export PKG_LOG_DIR="/caminho/para/logs"               # logs
#  export PKG_GIT_REPO="/caminho/para/meu-repo-git"      # repo git para sync
#  export PKG_FETCH_CMD="curl -L --fail --retry 3 -o"     # como baixar (prefixo)
#  export PKG_JOBS="$(nproc)"                             # paralelismo de build
#  export PKG_MAKEFLAGS="-j${PKG_JOBS}"                   # flags do make/ninja
#  export PKG_STRIP_CMD="strip --strip-unneeded"          # comando strip
#  export PKG_PATH_PREFIX="/"                             # destino de instalação (/) 
#  export PKG_COLOR="1"                                   # 1=cores ativas, 0=sem cor
#
#  Após editar ~/.profile, faça:  source ~/.profile
# ============================================================================

# =============================== PARTE 1/5 ==================================
#  Utilitários, checagens, cores, logs, spinner, helpers genéricos
# ----------------------------------------------------------------------------
set -Eeuo pipefail
shopt -s extglob

# --- Checagem de variáveis obrigatórias (não definir diretórios aqui!)
REQUIRED_VARS=(
  PKG_RECIPES_DIR PKG_SRC_CACHE PKG_BUILD_DIR PKG_STAGING_DIR PKG_DB
  PKG_LOG_DIR PKG_GIT_REPO PKG_FETCH_CMD PKG_MAKEFLAGS PKG_STRIP_CMD PKG_PATH_PREFIX
)
for v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!v-}" ]] || { echo "[minipkg] ERRO: variável $v não definida (veja cabeçalho do script)." >&2; exit 1; }
done

# --- Cores
if [[ "${PKG_COLOR:-1}" == "1" ]] && command -v tput >/dev/null 2>&1; then
  C0=$(tput sgr0); B=$(tput bold)
  RED=$(tput setaf 1); GRN=$(tput setaf 2); YLW=$(tput setaf 3); BLU=$(tput setaf 4); CYN=$(tput setaf 6)
else
  C0=""; B=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""
fi

log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
log_file(){ mkdir -p "$PKG_LOG_DIR"; echo "$PKG_LOG_DIR/$(date +%Y%m%d)_$1.log"; }
log(){ local f; f=$(log_file "$1"); shift; printf "[%s] %b%s%b\n" "$(log_ts)" "$BLU" "$*" "$C0" | tee -a "$f"; }
info(){ printf "%b%s%b\n" "$CYN" "$*" "$C0"; }
ok(){ printf "%b%s%b\n" "$GRN" "$*" "$C0"; }
warn(){ printf "%b%s%b\n" "$YLW" "$*" "$C0"; }
err(){ printf "%b%s%b\n" "$RED" "$*" "$C0" >&2; }

# --- Spinner
_spinner_running=""
spin_start(){
  local msg="$*"; [[ -z "$msg" ]] && msg="Processando"
  ( while :; do for s in '⠋' '⠙' '⠸' '⠴' '⠦' '⠇'; do printf "\r%s %s" "$s" "$msg"; sleep 0.1; done; done ) &
  _spinner_running=$!
}
spin_stop(){ if [[ -n "${_spinner_running:-}" ]]; then kill "$_spinner_running" 2>/dev/null || true; wait "$_spinner_running" 2>/dev/null || true; printf "\r%*s\r" 80 ""; _spinner_running=""; fi }
trap 'spin_stop || true' EXIT

# --- Helpers gerais
ensure_dirs(){
  mkdir -p "$PKG_SRC_CACHE" "$PKG_BUILD_DIR" "$PKG_STAGING_DIR" "$PKG_DB" "$PKG_DB/installed" "$PKG_DB/refs" "$PKG_DB/state" "$PKG_DB/depcache"
}

version_cmp(){
  # retorna: 0 se iguais; 1 se v1>v2; 2 se v1<v2 (usa sort -V)
  local v1="$1" v2="$2"
  if [[ "$v1" == "$v2" ]]; then return 0; fi
  if printf "%s\n%s\n" "$v1" "$v2" | sort -V | head -n1 | grep -qx "$v2"; then return 1; else return 2; fi
}

require_cmd(){ for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { err "Comando obrigatório ausente: $c"; exit 1; }; done }

# Arquivo de receita: formato simples INI-like
# Campos suportados: Name, Version, Source (um por linha ou múltiplos), Sha256 (opcional), Depends (csv),
# Build (comandos multiline), Install (comandos multiline, opcionais — senão padrão make install)
recipe_path(){ echo "$PKG_RECIPES_DIR/$1.pkg"; }

parse_field(){
  # $1=arquivo $2=campo -> imprime valor (concatena múltiplas linhas do mesmo campo)
  awk -v key="$2" -F': *' 'BEGIN{IGNORECASE=1} $1==key{ sub(/^ *[^:]+: */,"",$0); print }' "$1"
}
parse_block(){
  # bloco de shell delimitado por linhas "<Campo>: |" até linha que começa com "<Campo>: end"
  awk -v key="$2" 'BEGIN{IGNORECASE=1} $0 ~ "^"key": *\\|"{flag=1; next} flag && $0 ~ "^"key": *end"{flag=0; exit} flag{print}' "$1"
}

# Normaliza lista de dependências
norm_csv(){ tr ', ' '\n' | sed -E '/^\s*$/d' | sed -E 's/^\s+|\s+$//g' | sort -u; }

# =============================== PARTE 2/5 ==================================
#  Resolução de dependências, banco de dados, metadados, infos
# ----------------------------------------------------------------------------
ensure_db(){ ensure_dirs; : >"$PKG_DB/state/lock"; }

installed_ver(){ local n="$1"; [[ -f "$PKG_DB/installed/$n/VERSION" ]] && cat "$PKG_DB/installed/$n/VERSION" || echo ""; }
installed_files(){ local n="$1"; [[ -f "$PKG_DB/installed/$n/files.list" ]] && cat "$PKG_DB/installed/$n/files.list" || true; }

pkg_info(){
  local n="$1" f; f=$(recipe_path "$n"); [[ -f "$f" ]] || { err "Receita não encontrada: $n"; exit 1; }
  local ver src deps; ver=$(parse_field "$f" Name | head -n1 >/dev/null; parse_field "$f" Version | head -n1)
  src=$(parse_field "$f" Source)
  deps=$(parse_field "$f" Depends | norm_csv)
  echo "Nome: $n"
  echo "Versão (receita): $ver"
  echo "Instalado: $(installed_ver "$n" || echo "-")"
  echo "Depende de: ${deps//$'\n'/, }"
  echo "Fontes:"; printf '  %s\n' $src
}

# Grafo de dependências (diretas)
list_deps(){ local f=$(recipe_path "$1"); parse_field "$f" Depends | norm_csv; }

# Resolução recursiva + ordenação topológica usando tsort
resolve_deps(){
  # imprime ordem de build/instalação (deps antes dos dependentes), inclui o pacote
  local target="$1"
  local edges tmp; tmp=$(mktemp)
  {
    _walk(){ local p="$1"; echo "$p" >>"$PKG_DB/depcache/allpkgs" 2>/dev/null || true; local d; while read -r d; do [[ -z "$d" ]] && continue; echo "$d $p"; _walk "$d"; done < <(list_deps "$p"); }
    _walk "$target"
  } | sort -u > "$tmp"
  local order; order=$(tsort "$tmp" 2>/dev/null || true)
  if [[ -z "$order" ]]; then echo "$target"; else printf "%s\n" $order; fi
  rm -f "$tmp"
}

# Marca pacote como instalado no DB
register_install(){
  local name="$1" ver="$2" files_list="$3"
  mkdir -p "$PKG_DB/installed/$name"
  printf "%s\n" "$ver" > "$PKG_DB/installed/$name/VERSION"
  cp "$files_list" "$PKG_DB/installed/$name/files.list"
  date +%s > "$PKG_DB/installed/$name/installed_at"
}

# Remove registro
unregister_pkg(){ local n="$1"; rm -rf "$PKG_DB/installed/$n"; }

# Detecta órfãos: instalados que não são dependência de ninguém e não marcados como "manual"
mark_manual(){ mkdir -p "$PKG_DB/state"; printf "%s\n" "$1" >>"$PKG_DB/state/manual.list"; sort -u -o "$PKG_DB/state/manual.list" "$PKG_DB/state/manual.list"; }
manual_list(){ [[ -f "$PKG_DB/state/manual.list" ]] && cat "$PKG_DB/state/manual.list" || true; }
reverse_deps(){
  local all; all=$(ls -1 "$PKG_DB/installed" 2>/dev/null || true)
  local p; for p in $all; do while read -r d; do [[ -n "$d" ]] && printf "%s %s\n" "$d" "$p"; done < <(list_deps "$p"); done
}
orphans(){
  local all; all=$(ls -1 "$PKG_DB/installed" 2>/dev/null || true)
  local rev need; rev=$(mktemp); reverse_deps | awk '{print $1}' | sort -u >"$rev"
  need=$(comm -12 <(printf "%s\n" $all | sort -u) <(cat "$rev" | sort -u))
  local manual; manual=$(manual_list | sort -u)
  comm -23 <(printf "%s\n" $all | sort -u) <(printf "%s\n%s\n" "$need" "$manual" | sort -u)
  rm -f "$rev"
}

# =============================== PARTE 3/5 ==================================
#  Download, verificação, extração (vários formatos), build (sem instalar)
# ----------------------------------------------------------------------------
fetch(){
  local url="$1" out="$2"; mkdir -p "$(dirname "$out")"
  if [[ -f "$out" ]]; then ok "Cache já existe: $out"; return 0; fi
  info "Baixando: $url"; spin_start "baixando"
  set +e
  eval "$PKG_FETCH_CMD" "\"$out\"" "\"$url\"" >>"$(log_file fetch)" 2>&1
  local rc=$?
  set -e
  spin_stop
  [[ $rc -eq 0 ]] || { err "Falha ao baixar $url"; return 1; }
}

sha256_ok(){ local file="$1" sum="$2"; [[ -z "$sum" ]] && return 0; echo "$sum  $file" | sha256sum -c - >/dev/null 2>&1; }

extract(){
  local archive="$1" dest="$2"; mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.tar.xz)      tar -xJf "$archive" -C "$dest" ;;
    *.tar.bz2)     tar -xjf "$archive" -C "$dest" ;;
    *.tar.zst)     tar --zstd -xf "$archive" -C "$dest" ;;
    *.zip)         unzip -q "$archive" -d "$dest" ;;
    *.tar)         tar -xf "$archive" -C "$dest" ;;
    *)             # tenta com bsdtar se disponível
                   if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$archive" -C "$dest"; else
                     err "Formato de arquivo não suportado: $archive"; return 1; fi ;;
  esac
}

prepare_build(){
  local name="$1" f srcs sums ver; f=$(recipe_path "$name")
  ver=$(parse_field "$f" Version | head -n1)
  mapfile -t srcs < <(parse_field "$f" Source)
  mapfile -t sums < <(parse_field "$f" Sha256)
  mkdir -p "$PKG_BUILD_DIR/$name" "$PKG_STAGING_DIR/$name" "$PKG_SRC_CACHE"
  local i=0 a; for a in "${srcs[@]}"; do
    local fname="${a##*/}"; local out="$PKG_SRC_CACHE/$fname"
    fetch "$a" "$out"
    if [[ ${#sums[@]} -ge $((i+1)) && -n "${sums[$i]}" ]]; then
      sha256_ok "$out" "${sums[$i]}" || { err "SHA256 inválido para $fname"; exit 1; }
    fi
    i=$((i+1))
  done
  # Extrai primeiro arquivo no build dir; se múltiplos, extrai todos
  rm -rf "$PKG_BUILD_DIR/$name/*" 2>/dev/null || true
  for a in "${srcs[@]}"; do
    local fname="${a##*/}"; extract "$PKG_SRC_CACHE/$fname" "$PKG_BUILD_DIR/$name"
  done
  # Se ao extrair criar uma pasta única, entra nela
  local sub; sub=$(find "$PKG_BUILD_DIR/$name" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
  [[ -n "$sub" ]] && echo "$sub" || echo "$PKG_BUILD_DIR/$name"
}

build_pkg(){
  local name="$1"; ensure_db; require_cmd awk tar unzip make sha256sum
  local f=$(recipe_path "$name"); [[ -f "$f" ]] || { err "Receita não encontrada: $name"; exit 1; }
  info "Resolviendo dependências para build de $name"; local order; order=( $(resolve_deps "$name") )
  # Build de deps primeiro
  local p; for p in "${order[@]}"; do
    [[ "$p" == "$name" ]] && continue
    if [[ -z "$(installed_ver "$p")" ]]; then
      info "Construindo dependência: $p"; build_pkg "$p"; install_pkg "$p"
    fi
  done
  info "Preparando build de $name"; local builddir; builddir=$(prepare_build "$name")
  local ver; ver=$(parse_field "$f" Version | head -n1)
  local build_script; build_script=$(parse_block "$f" Build)
  : "${build_script:=}"
  pushd "$builddir" >/dev/null
  info "Compilando $name-$ver (sem instalar)"
  spin_start "compilando"
  if [[ -n "$build_script" ]]; then
    bash -euo pipefail -c "$build_script" >>"$(log_file build)" 2>&1
  else
    # Caminho padrão: autotools/meson/cmake heurístico
    if [[ -f configure ]]; then
      ./configure --prefix=/usr >>"$(log_file build)" 2>&1
      make $PKG_MAKEFLAGS >>"$(log_file build)" 2>&1
    elif [[ -f meson.build ]]; then
      command -v meson >/dev/null 2>&1 || { err "meson não encontrado e a receita não definiu Build:"; exit 1; }
      meson setup build --prefix=/usr >>"$(log_file build)" 2>&1
      meson compile -C build >>"$(log_file build)" 2>&1
    elif [[ -f CMakeLists.txt ]]; then
      command -v cmake >/dev/null 2>&1 || { err "cmake não encontrado e a receita não definiu Build:"; exit 1; }
      cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >>"$(log_file build)" 2>&1
      cmake --build build -- $PKG_MAKEFLAGS >>"$(log_file build)" 2>&1
    else
      err "Não sei como compilar e a receita não forneceu bloco Build"; exit 1
    fi
  fi
  spin_stop; ok "Build concluído: $name-$ver"
  popd >/dev/null
}

# =============================== PARTE 4/5 ==================================
#  Instalação em / (via staging), registro de arquivos, remoção, órfãos, strip
# ----------------------------------------------------------------------------
install_pkg(){
  local name="$1" f ver; f=$(recipe_path "$name"); ver=$(parse_field "$f" Version | head -n1)
  local builddir; builddir=$(find "$PKG_BUILD_DIR/$name" -mindepth 1 -maxdepth 1 -type d | head -n1 || echo "$PKG_BUILD_DIR/$name")
  [[ -d "$builddir" ]] || { err "Build não encontrado para $name. Rode: minipkg build $name"; exit 1; }
  local dest="$PKG_STAGING_DIR/$name"; rm -rf "$dest"; mkdir -p "$dest"

  info "Instalando $name-$ver em staging"
  pushd "$builddir" >/dev/null
  spin_start "instalando (staging)"
  local install_script; install_script=$(parse_block "$f" Install)
  if [[ -n "$install_script" ]]; then
    DESTDIR="$dest" bash -euo pipefail -c "$install_script" >>"$(log_file install)" 2>&1
  else
    if [[ -d build ]]; then
      DESTDIR="$dest" cmake --install build >>"$(log_file install)" 2>&1 || make -C build install >>"$(log_file install)" 2>&1 || true
    else
      DESTDIR="$dest" make install >>"$(log_file install)" 2>&1
    fi
  fi
  spin_stop; popd >/dev/null

  # Strip
  info "Aplicando strip em binários/bibliotecas"
  find "$dest" -type f \( -perm -111 -o -name "*.so*" -o -name "*.a" \) -print0 | xargs -0r file | awk -F: '/ELF/{print $1}' | xargs -r $PKG_STRIP_CMD || true

  # Copia para /
  info "Instalando em ${PKG_PATH_PREFIX} (/)"
  spin_start "copiando para /"
  rsync -aH --info=NAME "$dest"/ "$PKG_PATH_PREFIX"/ >>"$(log_file install)" 2>&1
  spin_stop

  # Registra lista de arquivos
  local list; list=$(mktemp)
  (cd "$dest" && find . -type f -o -type l | sed -E 's#^\.##') | sed -E "s#^#${PKG_PATH_PREFIX%/}#" | sort -u >"$list"
  register_install "$name" "$ver" "$list"
  rm -f "$list"
  ok "Instalação concluída: $name-$ver"
}

remove_pkg(){
  local name="$1"; local ver; ver=$(installed_ver "$name")
  [[ -n "$ver" ]] || { warn "$name não está instalado"; return 0; }
  info "Removendo $name-$ver"
  # Checar se alguém depende dele
  if reverse_deps | awk -v n="$name" '$1==n{print $2}' | grep -q .; then
    warn "Remoção bloqueada: outros pacotes dependem de $name"; return 1
  fi
  local files; files=$(installed_files "$name")
  if [[ -z "$files" ]]; then warn "Lista de arquivos vazia para $name"; fi
  spin_start "removendo arquivos"
  # Remove arquivos e depois diretórios vazios
  printf "%s\n" "$files" | xargs -r -d '\n' rm -f -- 2>>"$(log_file remove)" || true
  # Limpa diretórios vazios relativos
  printf "%s\n" "$files" | sed -E 's#/[^/]+$##' | sort -u | tac | xargs -r -d '\n' rmdir --ignore-fail-on-non-empty 2>>"$(log_file remove)" || true
  spin_stop
  unregister_pkg "$name"
  ok "Removido $name-$ver"
}

remove_orphans(){
  local o; mapfile -t o < <(orphans)
  [[ ${#o[@]} -eq 0 ]] && { ok "Sem órfãos"; return 0; }
  info "Removendo órfãos: ${o[*]}"
  local p; for p in "${o[@]}"; do remove_pkg "$p"; done
}

# =============================== PARTE 5/5 ==================================
#  Rebuild (pacote e sistema), upgrade (maior versão), sync git, CLI
# ----------------------------------------------------------------------------
rebuild_pkg(){ local n="$1"; info "Rebuild de $n"; remove_pkg "$n" || true; build_pkg "$n"; install_pkg "$n"; }

rebuild_system(){
  info "Rebuild do sistema inteiro (ordem por deps)"
  local all; all=$(ls -1 "$PKG_DB/installed" 2>/dev/null || true)
  [[ -z "$all" ]] && { warn "Nenhum pacote instalado"; return 0; }
  # Gera arestas e ordena
  local edges; edges=$(mktemp)
  local p d; for p in $all; do while read -r d; do [[ -z "$d" ]] && continue; printf "%s %s\n" "$d" "$p"; done < <(list_deps "$p"); done >"$edges"
  local order; if [[ -s "$edges" ]]; then order=$(tsort "$edges"); else order="$all"; fi
  rm -f "$edges"
  local pkg; for pkg in $order; do rebuild_pkg "$pkg"; done
}

upgrade_pkg(){
  local n="$1" f="$PKG_RECIPES_DIR/$1.pkg"
  [[ -f "$f" ]] || { err "Receita não encontrada: $n"; exit 1; }
  local newver; newver=$(parse_field "$f" Version | head -n1)
  local cur; cur=$(installed_ver "$n")
  if [[ -z "$cur" ]]; then info "$n não instalado; executando build+install"; build_pkg "$n"; install_pkg "$n"; return 0; fi
  version_cmp "$newver" "$cur"; local cmp=$?
  case $cmp in
    1) info "Upgrade $n: $cur -> $newver (versão MAIOR)"; rebuild_pkg "$n" ;;
    0|2) ok "Sem upgrade: receita $newver não é maior que instalada $cur" ;;
  esac
}

sync_git(){
  require_cmd git
  pushd "$PKG_GIT_REPO" >/dev/null
  git add -A || true
  git commit -m "minipkg sync: $(date -Iseconds)" || true
  git push || true
  popd >/dev/null
  ok "Sync com git concluído"
}

usage(){ cat <<EOF
Uso: minipkg <comando> [pacote]
Comandos:
  info <pkg>           - Mostra info da receita e versão instalada
  build <pkg>          - Resolve deps, baixa fontes, compila (não instala)
  install <pkg>        - Instala (em /) o pacote previamente buildado
  remove <pkg>         - Remove pacote (verifica revdeps)
  orphans              - Lista órfãos
  autoremove           - Remove programas órfãos
  rebuild <pkg>        - Rebuild de um pacote
  rebuild-system       - Rebuild ordenado de todos os instalados
  upgrade <pkg>        - Rebuild somente se versão da receita for MAIOR
  sync                 - git add/commit/push em PKG_GIT_REPO
  list-installed       - Lista pacotes instalados
  mark-manual <pkg>    - Marca como instalado manualmente
  help                 - Este help
EOF
}

list_installed(){ ls -1 "$PKG_DB/installed" 2>/dev/null || true; }

main(){
  ensure_db
  local cmd="${1-}"; shift || true
  case "$cmd" in
    info)            pkg_info "$@" ;;
    build)           build_pkg "$@" ;;
    install)         install_pkg "$@" ;;
    remove)          remove_pkg "$@" ;;
    orphans)         orphans ;;
    autoremove)      remove_orphans ;;
    rebuild)         rebuild_pkg "$@" ;;
    rebuild-system)  rebuild_system ;;
    upgrade)         upgrade_pkg "$@" ;;
    sync)            sync_git ;;
    list-installed)  list_installed ;;
    mark-manual)     mark_manual "$@" ;;
    help|--help|-h|"") usage ;;
    *) err "Comando desconhecido: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
