#!/usr/bin/env bash
# Собирает awg2 из src/ в один файл, который ставится одной командой curl.
#
#   ./build.sh              → dist/awg2.sh
#   ./build.sh путь/файл    → в указанный файл
#
# Порядок частей фиксирован списком ниже: модули объявляют только функции и
# константы, поэтому порядок важен лишь для констант, на которые ссылаются
# другие константы (const.sh идёт вторым).
set -euo pipefail

cd "$(dirname "$0")"
OUT="${1:-dist/awg2.sh}"

LIBS=(
  core const sys net conf module params mimicry server clients expire
  tunnels warp dns cascade xray tun2socks exits wgobf cert
  backup update bot web antiscan uninstall diag menu api cli
)

die() { echo "build: $*" >&2; exit 1; }

# Генератор CPS встраивается в одинарных кавычках, как в прежних версиях:
# Telegram-бот вырезает его из установленного awg2 по этим якорям.
grep -q "'" src/py/cpsgen.py && die "в src/py/cpsgen.py есть одинарная кавычка — она разорвёт встраивание"
grep -qx '__AWG2_PY_HELPER__' src/py/helper.py && die "в helper.py встречается строка-терминатор heredoc"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Буква тестовой сборки — только в показ версии
BUILD="${AWG_BUILD:-}"
[[ -z "$BUILD" || "$BUILD" =~ ^[a-z]$ ]] || die "AWG_BUILD — одна строчная буква"

{
  sed "s/^BUILD=\"\"$/BUILD=\"$BUILD\"/" src/head.sh
  for lib in "${LIBS[@]}"; do
    f="src/lib/${lib}.sh"
    [[ -f "$f" ]] || die "нет $f"
    printf '\n# ═════ %s ═════\n' "$lib"
    cat "$f"
  done

  printf '\n# ═════ встроенный Python ═════\n'
  echo "# CPS_GENERATOR_BEGIN v2 — генератор I1-I5 (порт payloadGen). Бот вырезает"
  echo "# этот блок из установленного awg2: якоря не переименовывать."
  printf "_CPS_GENERATOR='\n"
  cat src/py/cpsgen.py
  printf "'\n# CPS_GENERATOR_END v2\n\n"

  # Хеш — имя каталога закэшированного помощника: новая версия кода — новый каталог
  echo "_PY_HELPER_SUM=$(sha256sum src/py/helper.py | cut -c1-16)"
  echo "IFS= read -r -d '' _PY_HELPER <<'__AWG2_PY_HELPER__' || true"
  cat src/py/helper.py
  printf '__AWG2_PY_HELPER__\n\n'
} > "$tmp"
# Хеш всей сборки: по нему awg2 замечает новую сборку той же версии
{
  echo "_BUILD_SUM=$(sha256sum "$tmp" | cut -c1-16)"
  echo 'main "$@"'
} >> "$tmp"

bash -n "$tmp" || die "синтаксическая ошибка в собранном файле"
mkdir -p "$(dirname "$OUT")"
install -m 755 "$tmp" "$OUT"
echo "build: $OUT ($(wc -l < "$OUT") строк, $(( $(wc -c < "$OUT") / 1024 )) КБ)"
