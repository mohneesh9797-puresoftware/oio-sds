#!/usr/bin/env bash

CLI=$(command -v openio)
ADMIN_CLI=$(command -v openio-admin)
CONFIG=$(command -v oio-test-config.py)
NAMESPACE=$($CONFIG -n)
INTEGRITY="$(command -v oio-crawler-integrity)"
CONCURRENCY=10

# Some services declare their IP address and port as a service ID,
# and thus this check does not work anymore.
#SVCID_ENABLED=$(openio cluster list meta2 rawx -c 'Service Id' -f value | grep -v 'n/a')
SVCID_ENABLED=$(grep "service_id: true" ~/.oio/sds/conf/test.yml)
GRIDINIT="gridinit_cmd -S $HOME/.oio/sds/run/gridinit.sock"

usage() {
  echo "Usage: $(basename "${0}") -n namespace -c concurrency"
  echo "Example (default): $(basename "${0}") -n ${NAMESPACE} -c ${CONCURRENCY}"
  exit
}

while getopts ":n:c:p:" opt; do
  case $opt in
    n)
      echo "-n was triggered, Parameter: $OPTARG" >&2
      NAMESPACE=$OPTARG
      if [ -z "${NAMESPACE}" ]; then
        echo "Missing namespace name"
        exit 1
      fi
      ;;
    w)
      echo "-c was triggered, Parameter: $OPTARG" >&2
      CONCURRENCY=$OPTARG
      if [ -z "${CONCURRENCY}" ]; then
        echo "Missing number of coroutines"
        exit 1
      fi
      ;;
    *)
      usage
      exit 0
      ;;
  esac
done

PROXY=$($CONFIG -t proxy -1)

FAIL=false

TMP_VOLUME="${TMPDIR:-/tmp}/openio_volume_before"
TMP_FILE_BEFORE="${TMPDIR:-/tmp}/openio_file_before"
TMP_FILE_AFTER="${TMPDIR:-/tmp}/openio_file_after"
INTEGRITY_LOG="${TMPDIR:-/tmp}/integrity.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
NO_COLOR='\033[0m'

update_timeout()
{
  TIMEOUT=$1
  for META_TYPE in meta0 meta1 meta2; do
    $CLI cluster list "${META_TYPE}" -f value -c Addr \
        | while read -r URL; do
      curl -sS -X POST -d "{\"resolver.cache.csm0.ttl.default\": ${TIMEOUT}, \"resolver.cache.srv.ttl.default\": ${TIMEOUT}}" \
          "http://${PROXY}/v3.0/forward/config?id=${URL}" 1>/dev/null
    done
  done
  sleep 10
}

check_and_remove_meta()
{
  TYPE=$1

  META_COPY=$(/usr/bin/curl -sS -X POST \
      "http://${PROXY}/v3.0/${NAMESPACE}/lb/poll?pool=${TYPE}" 2> /dev/null \
      | /bin/grep -o "\"addr\":" | /usr/bin/wc -l)
  if [ "${META_COPY}" -le 0 ]; then
    echo >&2 "proxy: No response"
    exit 1
  fi
  if [ "${META_COPY}" -le 1 ]; then
    return
  fi

  OLD_IFS=$IFS
  IFS=' ' read -r META_IP_TO_REBUILD META_ID_TO_REBUILD META_LOC_TO_REBUILD <<< \
      "$($CLI cluster list "${TYPE}" -c Addr -c "Service Id" -c Volume \
      -f value | /usr/bin/shuf -n 1)"
  IFS=$OLD_IFS
  if [ -z "$SVCID_ENABLED" ] || [ "${META_ID_TO_REBUILD}" = "n/a" ]; then
    META_ID_TO_REBUILD=${META_IP_TO_REBUILD}
  fi

  SERVICE="${META_LOC_TO_REBUILD##*/}"
  echo >&2 "Stop the ${TYPE} ${META_ID_TO_REBUILD}"
  ${GRIDINIT} stop "${SERVICE}" > /dev/null

  echo >&2 "Remove the ${TYPE} ${META_ID_TO_REBUILD}"
  /bin/rm -rf "${TMP_VOLUME}"
  /bin/cp -a "${META_LOC_TO_REBUILD}" "${TMP_VOLUME}"
  /bin/rm -rf "${META_LOC_TO_REBUILD}"
  /bin/mkdir "${META_LOC_TO_REBUILD}"

  echo >&2 "Restart the ${TYPE} ${META_ID_TO_REBUILD}"
  ${GRIDINIT} restart "${SERVICE}" > /dev/null
  ${CLI} cluster wait -s 50 "${TYPE}" > /dev/null

  echo "${META_ID_TO_REBUILD} ${META_LOC_TO_REBUILD}"
}

openioadmin_meta_rebuild()
{
  set -e

  TYPE=$1

  mysqldiff()
  {
    if ! TABLES_1=$(/usr/bin/sqlite3 "${1}" ".tables" 2> /dev/null) \
        || [ -z "${TABLES_1}" ]; then
      return 1
    fi
    if ! TABLES_2=$(/usr/bin/sqlite3 "${2}" ".tables" 2> /dev/null) \
        || [ -z "${TABLES_2}" ]; then
      return 1
    fi
    if [ "${TABLES_1}" != "${TABLES_2}" ]; then
      echo >&2 "${TABLES_1}"
      echo >&2 "${TABLES_2}"
      return 0
    fi
    OLD_IFS=$IFS
    IFS=' '
    for TABLE in ${TABLES_1}; do
      if ! TABLE_1=$(/usr/bin/sqlite3 "${1}" "SELECT * FROM ${TABLE}" \
          2> /dev/null); then
        IFS=$OLD_IFS
        return 1
      fi
      if ! TABLE_2=$(/usr/bin/sqlite3 "${2}" "SELECT * FROM ${TABLE}" \
          2> /dev/null); then
        IFS=$OLD_IFS
        return 1
      fi
      if [ "${TABLE_1}" != "${TABLE_2}" ]; then
        echo >&2 "${TABLE_1}"
        echo >&2 "${TABLE_2}"
        IFS=$OLD_IFS
        return 0
      fi
    done
    IFS=$OLD_IFS
    return 0
  }

  echo ""
  echo "***** openio-admin ${TYPE} rebuild *****"
  echo ""

  if [ -n "$2" ] && [ -n "$3" ]; then
    META_ID_TO_REBUILD=$2
    META_LOC_TO_REBUILD=$3
  else
    META=$(check_and_remove_meta "${TYPE}")
    if [ -z "${META}" ]; then
      printf "\noio-%s-rebuilder: SKIP (need at least 2 %s to run)\n" \
        "${TYPE}" "${TYPE}"
      return
    fi
    OLD_IFS=$IFS
    IFS=' ' read -r META_ID_TO_REBUILD META_LOC_TO_REBUILD <<< "${META}"
    IFS=$OLD_IFS
  fi

  update_timeout 1
  REBULD_TIME=$(date +%s)
  set +e

  sleep 3s

  echo >&2 "Start the rebuilding for ${TYPE} ${META_ID_TO_REBUILD}" \
      "with ${CONCURRENCY} coroutines"
  if [ "${TYPE}" == "meta1" ]; then
    if ! $ADMIN_CLI $TYPE rebuild --concurrency "${CONCURRENCY}"; then
        FAIL=true
    fi
  else
    if ! $ADMIN_CLI $TYPE rebuild --concurrency "${CONCURRENCY}" "${META_ID_TO_REBUILD}"; then
        FAIL=true
    fi
  fi

  set -e
  update_timeout 0
  set +e

  echo >&2 "Check the differences"

  for META in ${TMP_VOLUME}/*/*; do
    if [ "${TYPE}" == "meta1" ]; then
      if ! USER=$(/usr/bin/sqlite3 "${META}" "SELECT user FROM users LIMIT 1" \
          2> /dev/null); then
        echo >&2 "${META}: sqlite3 failed for ${TYPE} ${META_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
      if [ -z "${USER}" ]; then
        echo >&2 "${META}: empty"
        continue
      fi
    fi

    META_AFTER=${META//"${TMP_VOLUME}"/"${META_LOC_TO_REBUILD}"}
    if ! [ -f "${META_AFTER}" ]; then
      echo >&2 "${META} not found at ${META_AFTER} (${TYPE} ${META_ID_TO_REBUILD})"
      FAIL=true
      continue
    fi

    if [ "${TYPE}" == "meta1" ]; then
      if ! LAST_REBUILD=$(/usr/bin/sqlite3 "${META_AFTER}" \
          "SELECT v FROM admin where k == 'user.sys.last_rebuild'" \
          2> /dev/null); then
        echo >&2 "${META}: sqlite3 failed for ${TYPE} ${META_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
      if [ -z "${LAST_REBUILD}" ]; then
        echo >&2 "${META}: no rebuild date found for ${TYPE} ${META_ID_TO_REBUILD}"
        FAIL=true
      elif [ "${REBULD_TIME}" -gt "${LAST_REBUILD}" ]; then
        echo >&2 "${META}: last rebuild date too old for ${TYPE} ${META_ID_TO_REBUILD}: ${LAST_REBUILD} < ${REBULD_TIME}"
        FAIL=true
        continue
      fi
    fi

    /bin/cp -a "${META}" "${TMP_FILE_BEFORE}"
    /bin/cp -a "${META_AFTER}" "${TMP_FILE_AFTER}"
    if ! /usr/bin/sqlite3 "${TMP_FILE_BEFORE}" \
        "DELETE FROM admin WHERE k == 'version:main.admin';
        DELETE FROM admin WHERE k == 'user.sys.last_rebuild'" &> /dev/null; then
      echo >&2 "${META}: sqlite3 failed for ${TYPE} ${META_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi
    /usr/bin/sqlite3 "${TMP_FILE_AFTER}" \
        "DELETE FROM admin WHERE k == 'version:main.admin';
        DELETE FROM admin WHERE k == 'user.sys.last_rebuild'" &> /dev/null
    if ! /usr/bin/sqlite3 "${TMP_FILE_AFTER}" \
        "DELETE FROM admin WHERE k == 'version:main.admin';
        DELETE FROM admin WHERE k == 'user.sys.last_rebuild'" &> /dev/null; then
      echo >&2 "${META}: sqlite3 failed for ${TYPE} ${META_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi
    if ! DIFF=$(mysqldiff "${TMP_FILE_BEFORE}" "${TMP_FILE_AFTER}" \
        2> /dev/null); then
      echo >&2 "${META}: sqldiff failed for ${TYPE} ${META_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi
    if [ -n "${DIFF}" ]; then
      echo >&2 "${META}: Wrong content for ${TYPE} ${META_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi
    echo -n '.'
  done

  if [ "${FAIL}" = true ]; then
    printf "${RED}\nopenio-admin %s rebuild: FAILED\n${NO_COLOR}" "${TYPE}"
    exit 1
  else
    printf "${GREEN}\nopenio-admin %s rebuild: OK\n${NO_COLOR}" "${TYPE}"
  fi
}

declare -A -x ID_TO_NETLOC

resolve_chunk()
{
  ID=$(echo "$1" | sed -E -n -e 's,http://([^/]+)/.*,\1,p')
  NETLOC="${ID_TO_NETLOC[$ID]}"
  if [ -z "$NETLOC" ]
  then
    NETLOC=$($CLI cluster resolve -f value rawx "$ID")
    ID_TO_NETLOC[$ID]="$NETLOC"
  fi
  echo "${1/$ID/$NETLOC}"
}

remove_rawx()
{
  OLD_IFS=$IFS
  IFS=' ' read -r RAWX_IP_TO_REBUILD RAWX_ID_TO_REBUILD RAWX_LOC_TO_REBUILD <<< \
      "$($CLI cluster list rawx -c Addr -c "Service Id" -c Volume -f value \
      | /usr/bin/shuf -n 1)"
  IFS=$OLD_IFS
  if [ -z "$SVCID_ENABLED" ] || [ "${RAWX_ID_TO_REBUILD}" = "n/a" ]; then
    RAWX_ID_TO_REBUILD=${RAWX_IP_TO_REBUILD}
  fi

  TOTAL_CHUNKS=0
  while read -r RAWX_LOC; do
    TOTAL_CHUNKS=$(( TOTAL_CHUNKS + $(/usr/bin/find "${RAWX_LOC}" -type f \
    | /usr/bin/wc -l) ))
  done < <($CLI cluster list rawx -c Volume -f value)

  SERVICE="${RAWX_LOC_TO_REBUILD##*/}"
  echo >&2 "Stop the rawx ${RAWX_ID_TO_REBUILD}"
  ${GRIDINIT} stop "${SERVICE}" > /dev/null

  echo >&2 "Remove data from the rawx ${RAWX_ID_TO_REBUILD}"
  /bin/rm -rf "${TMP_VOLUME}"
  /bin/cp -a "${RAWX_LOC_TO_REBUILD}" "${TMP_VOLUME}"
  /bin/rm -rf "${RAWX_LOC_TO_REBUILD}"
  /bin/mkdir "${RAWX_LOC_TO_REBUILD}"

  echo >&2 "Restart the rawx ${RAWX_ID_TO_REBUILD}"
  ${GRIDINIT} restart "${SERVICE}" > /dev/null
  ${CLI} cluster wait -s 50 rawx > /dev/null

  echo "${RAWX_ID_TO_REBUILD} ${RAWX_LOC_TO_REBUILD} ${TOTAL_CHUNKS}"
}

openioadmin_rawx_rebuild()
{
  rm -f "$INTEGRITY_LOG"
  set -e

  echo ""
  echo "***** openio-admin rawx rebuild *****"
  echo ""

  if [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]; then
    RAWX_ID_TO_REBUILD=$1
    RAWX_LOC_TO_REBUILD=$2
    TOTAL_CHUNKS=$3
  else
    RAWX=$(remove_rawx)
    if [ -z "${RAWX}" ]; then
      return
    fi
    OLD_IFS=$IFS
    IFS=' ' read -r RAWX_ID_TO_REBUILD RAWX_LOC_TO_REBUILD TOTAL_CHUNKS \
        <<< "${RAWX}"
    IFS=$OLD_IFS
  fi

  echo >&2 "Create an incident for rawx ${RAWX_ID_TO_REBUILD}"
  $CLI volume admin incident "${RAWX_ID_TO_REBUILD}"

  update_timeout 1
  set +e

  BEANSTALKD=$($CONFIG -t beanstalkd)
  MULTIBEANSTALKD=$(test $(echo "${BEANSTALKD}" | wc -l) -gt 1 && echo "true" || echo "false")
  if "${MULTIBEANSTALKD}" = true; then
    CLI_ACTION=distributed-rebuild
    BLOB_REBUILDER_OPTIONS=( )
  else
    CLI_ACTION=rebuild
    BLOB_REBUILDER_OPTIONS=( --concurrency "${CONCURRENCY}" )
  fi

  echo >&2 "Start the rebuilding for rawx ${RAWX_ID_TO_REBUILD}"
  if ! $ADMIN_CLI rawx $CLI_ACTION "${BLOB_REBUILDER_OPTIONS[@]}" \
      "${RAWX_ID_TO_REBUILD}"; then
    echo >&2 "openio-admin rawx $CLI_ACTION FAILED"
    FAIL=true
  fi

  set -e
  update_timeout 0
  set +e

  echo >&2 "Check the differences"
  START=$(date +%s)

  TOTAL_CHUNKS_AFTER=0
  while read -r RAWX_LOC; do
    TOTAL_CHUNKS_AFTER=$(( TOTAL_CHUNKS_AFTER + \
        $(/usr/bin/find "${RAWX_LOC}" -type f | /usr/bin/wc -l) ))
  done < <($CLI cluster list rawx -c Volume -f value)
  if [ "${TOTAL_CHUNKS}" -ne "${TOTAL_CHUNKS_AFTER}" ]; then
    echo >&2 "Wrong number of chunks:" \
        "before=${TOTAL_CHUNKS} after=${TOTAL_CHUNKS_AFTER}"
    FAIL=true
  fi

  for CHUNK in ${TMP_VOLUME}/*/*; do
    CHUNK_ID=${CHUNK##*/}
    if ! FULLPATH=$(/usr/bin/getfattr -n "user.oio.content.fullpath:${CHUNK_ID}" \
        --only-values "${CHUNK}" 2> /dev/null); then
      echo >&2 "${CHUNK}: Missing fullpath attribute for rawx ${RAWX_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi
    if ! POSITION=$(/usr/bin/getfattr -n "user.grid.chunk.position" \
        --only-values "${CHUNK}" 2> /dev/null); then
      echo >&2 "${CHUNK}: Missing attribute for rawx ${RAWX_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi

    OLD_IFS=$IFS
    IFS='/' read -r ACCOUNT CONTAINER CONTENT VERSION CONTENTID <<< "${FULLPATH}"
    IFS=$OLD_IFS

    if ! CHUNK_URLS=$($CLI object locate \
        --oio-account "${ACCOUNT}" "${CONTAINER}" "${CONTENT}" \
        --object-version "${VERSION}" -f value -c Pos -c Id \
        | /bin/grep "^${POSITION} " | /usr/bin/cut -d' ' -f2) \
        || [ -z "${CHUNK_URLS}" ]; then
      echo >&2 "${CHUNK}: Location failed for rawx ${RAWX_ID_TO_REBUILD}"
      FAIL=true
      continue
    fi
    OLD_IFS=$IFS
    IFS=$'\n'
    for CHUNK_URL in ${CHUNK_URLS}; do
      if [ "${CHUNK_URL##*/}" = "${CHUNK_ID}" ]; then
        echo >&2 "${CHUNK}: (${CHUNK_URL}) meta2 not updated for rawx ${RAWX_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
      if ! $INTEGRITY "$NAMESPACE" "${ACCOUNT}" \
          "${CONTAINER}" "${CONTENT}" "${CHUNK_URL}" &>> "$INTEGRITY_LOG"; then
        echo >&2 "${CHUNK}: (${CHUNK_URL}) oio-crawler-integrity failed for rawx ${RAWX_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
      # Maybe resolve the service ID into an IP:PORT couple, and fix the URL
      if [ -n "$SVCID_ENABLED" ]
      then
        CURLABLE=$(resolve_chunk "${CHUNK_URL}")
      else
        CURLABLE=${CHUNK_URL}
      fi
      # Download the reconstructed chunk
      if ! /usr/bin/wget -O "${TMP_FILE_AFTER}" "${CURLABLE}" \
          &> /dev/null; then
        echo >&2 "${CHUNK}: failed to download the rebuilt chunk (${CURLABLE}) ${RAWX_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
      EXPECT_MD5=$(getfattr -n user.grid.chunk.hash --only-values "${CHUNK}" 2>/dev/null)
      if ! ACTUAL_MD5=$(/usr/bin/md5sum "${TMP_FILE_AFTER}" | cut -d ' ' -f 1 2> /dev/null); then
        echo >&2 "${CHUNK}: failed to compute the checksum of the rebuilt chunk (${TMP_FILE_AFTER}) ${RAWX_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
      # Uppercase comparison
      if [ "${ACTUAL_MD5^^}" != "${EXPECT_MD5^^}" ]; then
        echo >&2 "${CHUNK}: ${TMP_FILE_AFTER} checksum mismatch (${EXPECT_MD5^^} vs ${ACTUAL_MD5^^}) ${RAWX_ID_TO_REBUILD}"
        FAIL=true
        continue
      fi
    done
    IFS=$OLD_IFS
    echo -n '.'
  done
  echo
  END=$(date +%s)
  echo "Verification duration: $((END - START))s"

  if [ "${FAIL}" = true ]; then
    printf "${RED}\nopenio-admin rawx rebuild: FAILED\n${NO_COLOR}"
    exit 1
  else
    echo >&2 "Remove the incident for rawx ${RAWX_ID_TO_REBUILD}"
    $CLI volume admin clear --before-incident "${RAWX_ID_TO_REBUILD}"

    printf "${GREEN}\nopenio-admin rawx rebuild: OK\n${NO_COLOR}"
  fi
}

openioadmin_all_rebuild()
{
  set -e

  echo ""
  echo "********** oio-all-rebuilders **********"
  echo ""

  META1=$(check_and_remove_meta "meta1")
  if [ -z "${META1}" ]; then
    printf "\noio-meta1-rebuilder: SKIP (need at least 2 meta1 to run)\n"
    return
  fi
  OLD_IFS=$IFS
  IFS=' ' read -r META1_ID_TO_REBUILD META1_LOC_TO_REBUILD <<< "${META1}"
  IFS=$OLD_IFS
  /bin/rm -rf "${TMP_VOLUME}_meta1"
  /bin/cp -a "${TMP_VOLUME}" "${TMP_VOLUME}_meta1"

  META2=$(check_and_remove_meta "meta2")
  if [ -z "${META2}" ]; then
    printf "\noio-meta2-rebuilder: SKIP (need at least 2 meta2 to run)\n"
    return
  fi
  OLD_IFS=$IFS
  IFS=' ' read -r META2_ID_TO_REBUILD META2_LOC_TO_REBUILD <<< "${META2}"
  IFS=$OLD_IFS
  /bin/rm -rf "${TMP_VOLUME}_meta2"
  /bin/cp -a "${TMP_VOLUME}" "${TMP_VOLUME}_meta2"

  RAWX=$(remove_rawx)
  if [ -z "${RAWX}" ]; then
    return
  fi
  OLD_IFS=$IFS
  IFS=' ' read -r RAWX_ID_TO_REBUILD RAWX_LOC_TO_REBUILD TOTAL_CHUNKS \
      <<< "${RAWX}"
  IFS=$OLD_IFS
  /bin/rm -rf "${TMP_VOLUME}_rawx"
  /bin/cp -a "${TMP_VOLUME}" "${TMP_VOLUME}_rawx"

  /bin/rm -rf "${TMP_VOLUME}"
  /bin/cp -a "${TMP_VOLUME}_meta1" "${TMP_VOLUME}"
  /bin/rm -rf "${TMP_VOLUME}_meta1"
  openioadmin_meta_rebuild "meta1" "${META1_ID_TO_REBUILD}" "${META1_LOC_TO_REBUILD}"

  /bin/rm -rf "${TMP_VOLUME}"
  /bin/cp -a "${TMP_VOLUME}_meta2" "${TMP_VOLUME}"
  /bin/rm -rf "${TMP_VOLUME}_meta2"
  openioadmin_meta_rebuild "meta2" "${META2_ID_TO_REBUILD}" "${META2_LOC_TO_REBUILD}"

  /bin/rm -rf "${TMP_VOLUME}"
  /bin/cp -a "${TMP_VOLUME}_rawx" "${TMP_VOLUME}"
  /bin/rm -rf "${TMP_VOLUME}_rawx"
  openioadmin_rawx_rebuild "${RAWX_ID_TO_REBUILD}" "${RAWX_LOC_TO_REBUILD}" "${TOTAL_CHUNKS}"
}

# These tests have been disabled to gain time during CI.
# They are indirectly called by openioadmin_all_rebuild anyway.
#openioadmin_meta_rebuild "meta1"
#openioadmin_meta_rebuild "meta2"
#openioadmin_rawx_rebuild
openioadmin_all_rebuild
