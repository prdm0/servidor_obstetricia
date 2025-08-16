#!/usr/bin/env bash
# install_r.sh
# Instala o R no diretório do usuário, usando padrão r_local_<versão>
# Requisitos: Linux, curl, tar, gcc/g++, gfortran, make

set -euo pipefail

# ---------- Configuração padrão ----------
PREFIX_DEFAULT="$HOME/.local/R"
BIN_DIR_DEFAULT="$HOME/.local/bin"
JOBS_DEFAULT="$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"
USE_OPENBLAS=1
HEADLESS=0
WITHOUT_RECOMMENDED=0
R_VERSION=""  # vazio = detectar última no CRAN
PREFIX="$PREFIX_DEFAULT"
BIN_DIR="$BIN_DIR_DEFAULT"

# ---------- Utilidades ----------
log()   { printf "\033[1;34m[i]\033[0m %s\n" "$*" >&2; }
ok()    { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }
err()   { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
cat <<EOF
Uso: $0 [opções]

Opções:
  --version X.Y.Z         Força a versão específica do R (ex: 4.5.1)
  --prefix DIR            Diretório base de instalação (padrão: $PREFIX_DEFAULT)
  --bindir DIR            Onde criar os atalhos R/Rscript (padrão: $BIN_DIR_DEFAULT)
  --jobs N                Paralelismo do make (padrão: $JOBS_DEFAULT)
  --headless              Compila sem X11/Cairo (ideal para servidor)
  --without-recommended   Não instala Recommended packages (mais rápido)
  --no-openblas           Não tentar linkar com OpenBLAS do sistema
  -h, --help              Mostra esta ajuda

Exemplos:
  $0
  $0 --headless
  $0 --version 4.5.1 --without-recommended --no-openblas
  $0 --prefix \$HOME/apps/R --bindir \$HOME/bin
EOF
}

JOBS="$JOBS_DEFAULT"

# ---------- Parse de argumentos ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)              R_VERSION="${2:-}"; shift 2;;
    --prefix)               PREFIX="${2:-}"; shift 2;;
    --bindir)               BIN_DIR="${2:-}"; shift 2;;
    --jobs)                 JOBS="${2:-}"; shift 2;;
    --no-openblas)          USE_OPENBLAS=0; shift;;
    --headless)             HEADLESS=1; shift;;
    --without-recommended)  WITHOUT_RECOMMENDED=1; shift;;
    -h|--help)              usage; exit 0;;
    *)                      die "Opção desconhecida: $1 (use --help)";;
  esac
done

# ---------- Checagens básicas ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1"; }

log "Checando pré-requisitos…"
for c in curl tar grep sed awk head tail sort uname; do need_cmd "$c"; done
for c in gcc g++ gfortran make; do
  if ! command -v "$c" >/dev/null 2>&1; then
    die "Compilador/ ferramenta ausente: $c.
Instale:
  - Debian/Ubuntu: sudo apt-get install build-essential gfortran
  - Fedora/RHEL:  sudo dnf groupinstall 'Development Tools' && sudo dnf install gcc-gfortran"
  fi
done
ok "Ferramentas básicas encontradas."

# ---------- Descobrir a última versão no CRAN ----------
get_latest_r_version() {
  local base="https://cloud.r-project.org/src/base/"
  log "Consultando CRAN por versão mais recente…"
  local major_dir
  major_dir="$(curl -fsSL "$base" | grep -Eo 'R-[0-9]/' | sort -V | tail -n1)" || die "Falha ao obter diretórios principais."
  [[ -n "$major_dir" ]] || die "Não foi possível detectar diretório principal de versões."
  local page="${base}${major_dir}"
  local latest
  latest="$(curl -fsSL "$page" \
    | grep -Eo 'R-[0-9]+\.[0-9]+\.[0-9]+\.tar\.(xz|gz)' \
    | sed -E 's/^R-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.(xz|gz)$/\1/' \
    | sort -V | tail -n1)"
  [[ -n "$latest" ]] || die "Não foi possível identificar a última versão no CRAN."
  echo "$latest"
}

if [[ -z "$R_VERSION" ]]; then
  R_VERSION="$(get_latest_r_version)"
fi

# Sanitiza e valida versão (apenas x.y.z)
R_VERSION="$(printf '%s' "$R_VERSION" | tr -d '\r' | tail -n1)"
if ! printf '%s' "$R_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  die "Detecção de versão falhou (obtido: '$R_VERSION')."
fi

ok "Versão alvo do R: ${R_VERSION}"

# ---------- Preparar diretórios ----------
INSTALL_DIR="${PREFIX}/r_local_${R_VERSION}"
SRC_ROOT="$(mktemp -d -t rsrc.XXXXXX)"
trap 'rm -rf "$SRC_ROOT"' EXIT

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# ---------- Baixar fonte (prefere .tar.xz) ----------
major="${R_VERSION%%.*}"
BASE_URL="https://cloud.r-project.org/src/base/R-${major}/"
TAR_XZ="R-${R_VERSION}.tar.xz"
TAR_GZ="R-${R_VERSION}.tar.gz"

ARCHIVE_URL=""
ARCHIVE_NAME=""

log "Verificando formato de arquivo disponível…"
if curl -fsI "${BASE_URL}${TAR_XZ}" >/dev/null 2>&1; then
  ARCHIVE_URL="${BASE_URL}${TAR_XZ}"
  ARCHIVE_NAME="${TAR_XZ}"
  ok "Usando pacote .tar.xz"
elif curl -fsI "${BASE_URL}${TAR_GZ}" >/dev/null 2>&1; then
  ARCHIVE_URL="${BASE_URL}${TAR_GZ}"
  ARCHIVE_NAME="${TAR_GZ}"
  ok "Usando pacote .tar.gz"
else
  die "Arquivo de origem do R não encontrado em ${BASE_URL}"
fi

log "Baixando ${ARCHIVE_URL}…"
curl -fL "${ARCHIVE_URL}" -o "${SRC_ROOT}/${ARCHIVE_NAME}"

log "Extraindo fontes…"
tar -C "$SRC_ROOT" -xf "${SRC_ROOT}/${ARCHIVE_NAME}"

SRC_DIR="${SRC_ROOT}/R-${R_VERSION}"
[[ -d "$SRC_DIR" ]] || die "Diretório de fontes não encontrado após extração."

# ---------- Detectar OpenBLAS (opcional) ----------
BLAS_FLAGS=""
if [[ "$USE_OPENBLAS" -eq 1 ]]; then
  log "Tentando detectar OpenBLAS do sistema (sem sudo)…"
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists openblas; then
    BLAS_FLAGS="$(pkg-config --libs openblas)"
    ok "OpenBLAS via pkg-config: ${BLAS_FLAGS}"
  else
    if ldconfig -p 2>/dev/null | grep -qi openblas; then
      BLAS_FLAGS="-lopenblas"
      ok "OpenBLAS detectado via ldconfig."
    elif ls /usr/lib*/libopenblas.* >/dev/null 2>&1 || ls /lib*/libopenblas.* >/dev/null 2>&1; then
      BLAS_FLAGS="-lopenblas"
      ok "OpenBLAS detectado em diretórios padrão."
    else
      warn "OpenBLAS não foi encontrado; seguindo com BLAS padrão."
    fi
  fi
fi

# ---------- Configurar flags ----------
CONFIGURE_FLAGS=( "--prefix=${INSTALL_DIR}" "--enable-R-shlib" "--with-readline=yes" )

if [[ "$HEADLESS" -eq 1 ]]; then
  CONFIGURE_FLAGS+=( "--with-x=no" "--with-cairo=no" )
else
  CONFIGURE_FLAGS+=( "--with-x=yes" "--with-cairo=yes" "--with-libpng=yes" "--with-jpeglib=yes" "--with-libtiff=yes" )
fi

if [[ "$WITHOUT_RECOMMENDED" -eq 1 ]]; then
  CONFIGURE_FLAGS+=( "--without-recommended-packages" )
fi

if [[ -n "$BLAS_FLAGS" ]]; then
  CONFIGURE_FLAGS+=( "BLAS_LIBS=${BLAS_FLAGS}" )
fi

# ---------- Compilar e instalar ----------
log "Configurando build…"
pushd "$SRC_DIR" >/dev/null

set +e
./configure "${CONFIGURE_FLAGS[@]}"
CFG_STATUS=$?
set -e

if [[ $CFG_STATUS -ne 0 ]]; then
  warn "configure falhou com flags atuais; tentando configuração reduzida…"
  CONFIGURE_FLAGS=( "--prefix=${INSTALL_DIR}" "--enable-R-shlib" "--with-readline=no" )
  [[ "$HEADLESS" -eq 1 ]] && CONFIGURE_FLAGS+=( "--with-x=no" "--with-cairo=no" )
  [[ -n "$BLAS_FLAGS" ]] && CONFIGURE_FLAGS+=( "BLAS_LIBS=${BLAS_FLAGS}" )
  ./configure "${CONFIGURE_FLAGS[@]}" || die "configure falhou mesmo no modo reduzido."
fi
ok "configure concluído."

log "Compilando (make -j${JOBS})…"
make -j"${JOBS}"
ok "Build concluído."

log "Instalando em ${INSTALL_DIR}…"
make install
ok "Instalação concluída."

popd >/dev/null

# ---------- Symlinks/“current” ----------
mkdir -p "$BIN_DIR"
ln -sf "${INSTALL_DIR}/bin/R"        "${BIN_DIR}/R"
ln -sf "${INSTALL_DIR}/bin/Rscript"  "${BIN_DIR}/Rscript"
ln -sfn "${INSTALL_DIR}" "${PREFIX}/current"

ok "Atalhos criados em ${BIN_DIR}: R e Rscript"

# ---------- PATH & R_LIBS_USER ----------
SHELL_RC="$HOME/.bashrc"
if [[ -n "${SHELL:-}" ]]; then
  case "$(basename "$SHELL")" in
    zsh)  SHELL_RC="$HOME/.zshrc";;
    fish) SHELL_RC="$HOME/.config/fish/config.fish";;
    *)    SHELL_RC="$HOME/.bashrc";;
  esac
fi

export_lines='# >>> r-local (adicionado pelo install_r.sh) >>>
export PATH="$HOME/.local/bin:$PATH"
export R_LIBS_USER="${HOME}/R/library"
# <<< r-local <<<'

if ! grep -Fq '>>> r-local' "$SHELL_RC" 2>/dev/null; then
  log "Adicionando PATH e R_LIBS_USER em ${SHELL_RC}…"
  printf "\n%s\n" "$export_lines" >> "$SHELL_RC"
  ok "Linha adicionada a ${SHELL_RC}. Abra um novo terminal para carregar."
else
  warn "Bloco PATH/R_LIBS_USER já presente em ${SHELL_RC}; não modificado."
fi

# ---------- Verificação rápida ----------
log "Verificando versão instalada…"
if "${BIN_DIR}/R" --version | head -n1 | grep -q "${R_VERSION}"; then
  ok "R ${R_VERSION} instalado com sucesso em ${INSTALL_DIR}"
  echo
  echo "Dicas:"
  echo "  - Abra um novo terminal (ou 'source ${SHELL_RC}') para usar 'R' direto do PATH."
  echo "  - Suas libs de usuário ficarão em: \$R_LIBS_USER (${HOME}/R/library)"
  echo "  - Instalações ficam em ${PREFIX}/r_local_<versão> e o link 'current'."
else
  die "Algo deu errado: o R instalado não reporta a versão esperada."
fi
