#!/usr/bin/env bash
# install_r_robusto.sh
#
# Instala o R em um diretório de usuário, de forma autônoma.
# - Detecta e instala um compilador GCC/Fortran localmente se não estiver presente (toolchain pré-compilada).
# - Ajusta LD_LIBRARY_PATH para expor as bibliotecas runtime (libgfortran, libquadmath, etc).
# - Detecta, baixa e compila dependências essenciais (zlib, bzip2, xz, pcre2, curl) se não estiverem no sistema.
# - Cria wrappers para R/Rscript que carregam o ambiente correto.
# - Mantém a instalação organizada em ~/.local por padrão.

set -euo pipefail

# --- Configurações Padrão ---
# Diretórios
PREFIX_DEFAULT="$HOME/.local"
BIN_DIR_DEFAULT="$HOME/.local/bin"
# Compilação
JOBS_DEFAULT="$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"
# Versão do R (vazio para detectar a mais recente)
R_VERSION=""
# Versão do GCC para baixar se necessário (toolchain pré-compilada)
GCC_VERSION="12.3.0"
# Flags de controle
HEADLESS=0
WITHOUT_RECOMMENDED=0
FORCE_GCC_DOWNLOAD=0

# --- Funções de Utilidade (Logging) ---
log()   { printf "\033[1;34m[i]\033[0m %s\n" "$*" >&2; }
ok()    { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }
err()   { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

# --- Ajuda ---
usage() {
cat <<EOF
Uso: $0 [opções]

Este script baixa e compila uma versão do R no diretório do usuário.
Se um compilador Fortran ou dependências essenciais (bzip2, pcre2, etc.) não forem encontrados,
ele tentará baixá-los e compilá-los localmente.

Opções:
  --version X.Y.Z         Força a instalação de uma versão específica do R (ex: 4.3.1).
  --prefix DIR            Diretório base para todas as instalações (padrão: $PREFIX_DEFAULT).
  --bindir DIR            Onde criar os links/WRAPPERS R/Rscript (padrão: $BIN_DIR_DEFAULT).
  --jobs N                Número de processos paralelos para 'make' (padrão: $JOBS_DEFAULT).
  --headless              Compila sem suporte a X11/Cairo (ideal para servidores).
  --without-recommended   Não instala os pacotes "Recommended" (instalação mais rápida).
  --force-gcc-download    Força o download do compilador GCC mesmo que um já exista.
  -h, --help              Mostra esta mensagem de ajuda.
EOF
}

# --- Processamento de Argumentos ---
PREFIX="$PREFIX_DEFAULT"
BIN_DIR="$BIN_DIR_DEFAULT"
JOBS="$JOBS_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)              R_VERSION="${2:-}"; shift 2;;
    --prefix)               PREFIX="${2:-}"; shift 2;;
    --bindir)               BIN_DIR="${2:-}"; shift 2;;
    --jobs)                 JOBS="${2:-}"; shift 2;;
    --headless)             HEADLESS=1; shift;;
    --without-recommended)  WITHOUT_RECOMMENDED=1; shift;;
    --force-gcc-download)   FORCE_GCC_DOWNLOAD=1; shift;;
    -h|--help)              usage; exit 0;;
    *)                      die "Opção desconhecida: $1 (use --help)";;
  esac
done

# Variável global para reuso em wrappers
TOOLCHAIN_DIR=""

# --- Gerenciamento do Compilador ---
setup_compilers() {
  log "Verificando compiladores C, C++ e Fortran..."
  if [[ "$FORCE_GCC_DOWNLOAD" -eq 0 ]] && command -v gcc &>/dev/null && command -v g++ &>/dev/null && command -v gfortran &>/dev/null; then
    ok "Compiladores GCC (gcc, g++, gfortran) encontrados no sistema."
    log "Versão do GCC: $(gcc --version | head -n1)"
    # Não precisamos definir TOOLCHAIN_DIR aqui; usaremos as libs do sistema.
    return
  fi

  if [[ "$FORCE_GCC_DOWNLOAD" -eq 1 ]]; then
      warn "Opção --force-gcc-download ativada. Baixando compilador."
  else
      warn "Compilador Fortran (gfortran) não encontrado. Tentando baixar uma toolchain GCC local."
  fi

  local toolchain_dir="${PREFIX}/toolchains/gcc-${GCC_VERSION}"
  if [[ -f "${toolchain_dir}/bin/gcc" ]]; then
    log "Toolchain GCC local já parece estar instalada em ${toolchain_dir}"
  else
    local gcc_url="https://github.com/xpack-dev-tools/gcc-xpack/releases/download/v${GCC_VERSION}-2/xpack-gcc-${GCC_VERSION}-2-linux-x64.tar.gz"
    log "Baixando toolchain GCC ${GCC_VERSION}..."
    mkdir -p "${toolchain_dir}"
    local tmp_archive; tmp_archive="$(mktemp -t gcc.XXXXXX.tar.gz)"
    trap 'rm -f "$tmp_archive"' RETURN

    curl -L --progress-bar --fail "$gcc_url" -o "$tmp_archive" || die "O download do compilador falhou. Verifique a URL e sua conexão."

    log "Extraindo toolchain para ${toolchain_dir}..."
    tar -xzf "$tmp_archive" -C "${toolchain_dir}" --strip-components=1
    ok "Toolchain GCC extraída com sucesso."
  fi

  log "Configurando ambiente para usar a toolchain local."
  export PATH="${toolchain_dir}/bin:$PATH"

  # 🔧 FIX principal: garantir que runtimes (libgfortran, libquadmath, libgomp) sejam encontrados
  if [[ -d "${toolchain_dir}/lib64" ]]; then
      export LD_LIBRARY_PATH="${toolchain_dir}/lib64:${LD_LIBRARY_PATH:-}"
  fi
  if [[ -d "${toolchain_dir}/lib" ]]; then
      export LD_LIBRARY_PATH="${toolchain_dir}/lib:${LD_LIBRARY_PATH:-}"
  fi

  if ! command -v gfortran &>/dev/null; then die "Falha ao configurar a toolchain GCC local. 'gfortran' ainda não está no PATH."; fi
  TOOLCHAIN_DIR="${toolchain_dir}"
  ok "Compilador Fortran agora está disponível em: $(command -v gfortran)"
  ok "Bibliotecas runtime do GCC disponíveis em LD_LIBRARY_PATH."
}

# --- Gerenciamento de Dependências Essenciais ---
ensure_dependency() {
    local name="$1" header="$2" url="$3" configure_flags="${4:-}"
    local install_dir="${PREFIX}/deps/${name}"

    log "Verificando dependência: ${name}"
    if gcc -E - >/dev/null 2>&1 <<< "#include <${header}>"; then
        ok "${name} encontrado no sistema."
        return
    fi

    warn "${name} não encontrado no sistema. Será compilado localmente."
    if [[ -f "${install_dir}/include/${header}" ]]; then
        ok "${name} já foi compilado localmente em ${install_dir}"
    else
        log "Baixando ${name}..."
        local tmp_src_dir; tmp_src_dir="$(mktemp -d -t ${name}.XXXXXX)"
        (
            cd "$tmp_src_dir"
            curl -L --fail "$url" | tar -xz --strip-components=1 || die "Download ou extração de ${name} falhou."

            log "Configurando e compilando ${name}..."
            local cflags_for_dep="-fPIC"

            if [[ -f "./configure" ]]; then
                ./configure --prefix="${install_dir}" CFLAGS="${cflags_for_dep}" ${configure_flags}
            fi

            if [[ "$name" == "bzip2" ]]; then
                make -j"${JOBS}" CFLAGS="${cflags_for_dep}"
                make install PREFIX="${install_dir}"
            else
                make -j"${JOBS}"
                make install
            fi
        )
        rm -rf "$tmp_src_dir"
        ok "${name} compilado e instalado em ${install_dir}"
    fi

    export CPPFLAGS="-I${install_dir}/include ${CPPFLAGS:-}"
    export LDFLAGS="-L${install_dir}/lib ${LDFLAGS:-}"
    if [[ -d "${install_dir}/bin" ]]; then
        export PATH="${install_dir}/bin:$PATH"
    fi
    # ajuda pkg-config a achar as libs locais
    if [[ -d "${install_dir}/lib/pkgconfig" ]]; then
        export PKG_CONFIG_PATH="${install_dir}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    fi
}

ensure_all_dependencies() {
    log "Verificando dependências essenciais de compilação..."
    mkdir -p "${PREFIX}/deps"
    ensure_dependency "zlib"  "zlib.h"         "https://www.zlib.net/zlib-1.3.1.tar.gz"
    ensure_dependency "bzip2" "bzlib.h"        "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"
    ensure_dependency "xz"    "lzma.h"         "https://github.com/tukaani-project/xz/releases/download/v5.4.6/xz-5.4.6.tar.gz"
    ensure_dependency "pcre2" "pcre2.h"        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.43/pcre2-10.43.tar.gz" "--enable-utf --enable-unicode"
    ensure_dependency "curl"  "curl/curl.h"    "https://curl.se/download/curl-8.7.1.tar.gz"
    ok "Verificação de dependências concluída."
}

# --- Lógica Principal ---
# Diretório de build temporário no HOME (evitar /tmp pequeno)
log "Configurando diretório de build temporário em $HOME..."
SRC_ROOT="$(mktemp -d -p "${HOME}" r_build.XXXXXX)"
trap 'rm -rf "$SRC_ROOT"' EXIT
export TMPDIR="$SRC_ROOT"
ok "Diretório de build temporário: $SRC_ROOT"

log "Verificando ferramentas básicas..."
for cmd in curl tar grep sed awk make uname file; do
    command -v "$cmd" >/dev/null 2>&1 || die "Comando essencial não encontrado: '$cmd'."
done
ok "Ferramentas básicas encontradas."

# 1. Configurar compiladores (baixar se necessário)
setup_compilers

# 2. Garantir que as dependências essenciais existam (compilar se necessário)
ensure_all_dependencies

# 3. Determinar a versão do R
if [[ -z "$R_VERSION" ]]; then
  log "Consultando CRAN pela versão mais recente do R..."
  # tenta série R-4 primeiro
  R_VERSION=$(curl -s "https://cloud.r-project.org/src/base/R-4/" | grep -oE 'R-[0-9]+\.[0-9]+\.[0-9]+' | sed 's/R-//' | sort -rV | head -n1)
  if [[ -z "$R_VERSION" ]]; then
    # fallback genérico
    R_VERSION=$(curl -s "https://cloud.r-project.org/src/base/" | grep -oE 'R-[0-9]+\.[0-9]+\.[0-9]+' | sed 's/R-//' | sort -rV | head -n1)
  fi
  [[ -n "$R_VERSION" ]] || die "Não foi possível detectar a versão mais recente do R."
fi
ok "Versão do R a ser instalada: ${R_VERSION}"

# 4. Preparar diretórios de instalação
INSTALL_DIR="${PREFIX}/R/R-${R_VERSION}"
if [[ -d "$INSTALL_DIR" ]]; then warn "O diretório de instalação ${INSTALL_DIR} já existe."; fi
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# 5. Baixar o código-fonte do R
R_MAJOR="${R_VERSION%%.*}"
R_TARBALL="R-${R_VERSION}.tar.gz"
R_URL="https://cloud.r-project.org/src/base/R-${R_MAJOR}/${R_TARBALL}"

log "Baixando ${R_URL}..."
curl -L --progress-bar --fail "${R_URL}" -o "${SRC_ROOT}/${R_TARBALL}" || die "Download do R falhou."

log "Extraindo código-fonte..."
tar -C "$SRC_ROOT" -xzf "${SRC_ROOT}/${R_TARBALL}"
SRC_DIR="${SRC_ROOT}/R-${R_VERSION}"

# 6. Configurar a compilação (inclui rpath para bibliotecas locais)
log "Configurando o build do R..."
cd "$SRC_DIR"

CONFIGURE_FLAGS=(
  "--prefix=${INSTALL_DIR}"
  "--enable-R-shlib"
  "--with-recommended-packages=$([[ $WITHOUT_RECOMMENDED -eq 1 ]] && echo no || echo yes)"
)

# Detecta recursos gráficos
if gcc -E - >/dev/null 2>&1 <<< "#include <readline/readline.h>"; then CONFIGURE_FLAGS+=("--with-readline=yes"); else CONFIGURE_FLAGS+=("--with-readline=no"); fi
if [[ "$HEADLESS" -eq 1 ]]; then
  CONFIGURE_FLAGS+=( "--with-x=no" "--with-cairo=no" )
else
  if gcc -E - >/dev/null 2>&1 <<< "#include <X11/Xlib.h>"; then CONFIGURE_FLAGS+=("--with-x=yes"); else CONFIGURE_FLAGS+=("--with-x=no"); fi
  if gcc -E - >/dev/null 2>&1 <<< "#include <cairo.h>"; then CONFIGURE_FLAGS+=("--with-cairo=yes"); else CONFIGURE_FLAGS+=("--with-cairo=no"); fi
fi

# RPATH: garanta que o binário do R encontre libs locais mesmo fora desta sessão
RPATHS=()
for dep in zlib bzip2 xz pcre2 curl; do
  [[ -d "${PREFIX}/deps/${dep}/lib" ]] && RPATHS+=("${PREFIX}/deps/${dep}/lib")
done
# toolchain local (se existir)
if [[ -n "${TOOLCHAIN_DIR}" ]]; then
  [[ -d "${TOOLCHAIN_DIR}/lib64" ]] && RPATHS+=("${TOOLCHAIN_DIR}/lib64")
  [[ -d "${TOOLCHAIN_DIR}/lib"  ]] && RPATHS+=("${TOOLCHAIN_DIR}/lib")
fi

if [[ "${#RPATHS[@]}" -gt 0 ]]; then
  export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,$(IFS=:; echo "${RPATHS[*]}")"
fi

log "Executando ./configure..."
if ! ./configure "${CONFIGURE_FLAGS[@]}"; then
  err "A configuração do R falhou. Verifique a saída de erro acima."
  die "Build abortado."
fi
ok "Configuração concluída."

# 7. Compilar e Instalar
log "Compilando R com ${JOBS} processos (make -j${JOBS})... Isso pode demorar."
make -j"${JOBS}"
ok "Compilação concluída."

log "Instalando R em ${INSTALL_DIR}..."
make install
ok "Instalação concluída."

# 8. Criar wrappers robustos (em vez de apenas symlinks)
log "Criando wrappers em ${BIN_DIR} garantindo LD_LIBRARY_PATH..."

mkdir -p "${BIN_DIR}"

WRAP_ENV_FILE="${PREFIX}/R/env.sh"
cat > "${WRAP_ENV_FILE}" <<'ENVSH'
# Ambiente para executar R instalado localmente
# (carregado pelos wrappers R/Rscript)
# OBS: ESTE ARQUIVO É GERADO PELO INSTALADOR
# Edite com cuidado se precisar customizar.
ENVSH

# Preenche env.sh com LD_LIBRARY_PATH cumulativo
{
  echo 'export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"'
  # deps locais
  for dep in zlib bzip2 xz pcre2 curl; do
    libdir="${PREFIX}/deps/${dep}/lib"
    echo "[[ -d \"$libdir\" ]] && export LD_LIBRARY_PATH=\"$libdir:${LD_LIBRARY_PATH}\""
  done
  # toolchain local, se existir
  if [[ -n "${TOOLCHAIN_DIR}" ]]; then
    [[ -d "${TOOLCHAIN_DIR}/lib64" ]] && echo "export LD_LIBRARY_PATH=\"${TOOLCHAIN_DIR}/lib64:\${LD_LIBRARY_PATH}\""
    [[ -d "${TOOLCHAIN_DIR}/lib"  ]] && echo "export LD_LIBRARY_PATH=\"${TOOLCHAIN_DIR}/lib:\${LD_LIBRARY_PATH}\""
  fi
} >> "${WRAP_ENV_FILE}"

# Wrapper R
cat > "${BIN_DIR}/R" <<WRAP
#!/usr/bin/env bash
# Wrapper gerado pelo instalador - garante libs em runtime
PREFIX="${PREFIX}"
INSTALL_DIR="${INSTALL_DIR}"
# shellcheck disable=SC1090
source "\${PREFIX}/R/env.sh"
exec "\${INSTALL_DIR}/bin/R" "\$@"
WRAP
chmod +x "${BIN_DIR}/R"

# Wrapper Rscript
cat > "${BIN_DIR}/Rscript" <<WRAP
#!/usr/bin/env bash
# Wrapper gerado pelo instalador - garante libs em runtime
PREFIX="${PREFIX}"
INSTALL_DIR="${INSTALL_DIR}"
# shellcheck disable=SC1090
source "\${PREFIX}/R/env.sh"
exec "\${INSTALL_DIR}/bin/Rscript" "\$@"
WRAP
chmod +x "${BIN_DIR}/Rscript"

# Symlink "current" para conveniência
ln -sfn "${INSTALL_DIR}" "${PREFIX}/R/current"
ok "Wrappers R, Rscript e link 'current' criados."

# 9. Mensagem final e verificação
log "Verificação final..."
INSTALLED_R_VERSION=$("${BIN_DIR}/R" --version | head -n1 || true)
if [[ "$INSTALLED_R_VERSION" != *"R version ${R_VERSION}"* ]]; then
  err "Atenção: a versão relatada por '${BIN_DIR}/R --version' não casa com a esperada."
  err "Relato: '${INSTALLED_R_VERSION}' | Esperado: 'R version ${R_VERSION}'"
  die "Verificação falhou! Confira logs e ambiente."
fi

ok "R ${R_VERSION} foi instalado com sucesso!"
echo
echo "--- Próximos Passos ---"
echo "1. Garanta que '${BIN_DIR}' esteja no seu PATH (adicione ao ~/.bashrc ou ~/.zshrc):"
echo "   export PATH=\"${BIN_DIR}:\$PATH\""
echo
echo "2. Abra um NOVO terminal e execute 'R' para iniciar."
echo "   A instalação está em: ${INSTALL_DIR}"
echo "   A versão ativa está em: ${PREFIX}/R/current"
echo
echo "Dica: se você quiser rodar o binário real diretamente (sem o wrapper),"
echo "      assegure-se de exportar manualmente um LD_LIBRARY_PATH contendo:"
echo "      - libs das dependências em ${PREFIX}/deps/*/lib"
if [[ -n "${TOOLCHAIN_DIR}" ]]; then
  echo "      - libs da toolchain: ${TOOLCHAIN_DIR}/lib64 e/ou ${TOOLCHAIN_DIR}/lib"
fi
