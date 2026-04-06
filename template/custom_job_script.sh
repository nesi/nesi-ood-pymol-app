
cd "$SESSION_DIR"

# Export useful connection variables
export host
export port

# Generate a connection yaml file with given parameters
create_yml () {
  echo "Generating connection YAML file..."
  (
    umask 077
    echo -e "host: $host\nport: $port\npassword: $password\ndisplay: $display\nwebsocket: $websocket\nspassword: $spassword" > "${SESSION_DIR}/connection.yml"
  )
}

# Cleanliness is next to Godliness
clean_up () {
  echo "Cleaning up..."
  [[ -e "${SESSION_DIR}/clean.sh" ]] && source "${SESSION_DIR}/clean.sh"

  vncserver -list | awk '/^:/{system("kill -0 "$2" 2>/dev/null || vncserver -kill "$1)}'
  [[ -n ${display} ]] && vncserver -kill :${display}

  [[ ${SCRIPT_PID} ]] && pkill -P ${SCRIPT_PID} || :
  pkill -P $$
  exit ${1:-0}
}

# Source in all the helper functions
source_helpers () {
  # Generate random integer in range [$1..$2]
  random_number () {
    shuf -i ${1}-${2} -n 1
  }
  export -f random_number

  port_used_python() {
    python -c "import socket; socket.socket().connect(('$1',$2))" >/dev/null 2>&1
  }

  port_used_python3() {
    python3 -c "import socket; socket.socket().connect(('$1',$2))" >/dev/null 2>&1
  }

  port_used_nc(){
    nc -w 2 "$1" "$2" < /dev/null > /dev/null 2>&1
  }

  port_used_lsof(){
    lsof -i :"$2" >/dev/null 2>&1
  }

  port_used_bash(){
    local bash_supported=$(strings /bin/bash 2>/dev/null | grep tcp)
    if [ "$bash_supported" == "/dev/tcp/*/*" ]; then
      (: < /dev/tcp/$1/$2) >/dev/null 2>&1
    else
      return 127
    fi
  }

  # Check if port $1 is in use
  port_used () {
    local port="${1#*:}"
    local host=$((expr "${1}" : '\(.*\):' || echo "localhost") | awk 'END{print $NF}')
    local port_strategies=(port_used_nc port_used_lsof port_used_bash port_used_python port_used_python3)

    for strategy in ${port_strategies[@]};
    do
      $strategy $host $port
      status=$?
      if [[ "$status" == "0" ]] || [[ "$status" == "1" ]]; then
        return $status
      fi
    done

    return 127
  }
  export -f port_used

  # Find available port in range [$2..$3] for host $1
  # Default host: localhost
  # Default port range: [2000..65535]
  # returns error code (0: success, 1: failed)
  # On success, the chosen port is echoed on stdout.
  find_port () {
    local host="${1:-localhost}"
    local min_port=${2:-2000}
    local max_port=${3:-65535}
    local port_range=($(shuf -i ${min_port}-${max_port}))
    local retries=1 # number of retries over the port range if first attempt fails
    for ((attempt=0; attempt<=$retries; attempt++)); do
      for port in "${port_range[@]}"; do
        if port_used "${host}:${port}"; then
continue
        fi
        echo "${port}"
        return 0 # success
      done
    done

    echo "error: failed to find available port in range ${min_port}..${max_port}" >&2
    return 1 # failure
  }
  export -f find_port

  # Wait $2 seconds until port $1 is in use
  # Default: wait 30 seconds
  wait_until_port_used () {
    local port="${1}"
    local time="${2:-30}"
    for ((i=1; i<=time*2; i++)); do
      port_used "${port}"
      port_status=$?
      if [ "$port_status" == "0" ]; then
        return 0
      elif [ "$port_status" == "127" ]; then
         echo "commands to find port were either not found or inaccessible."
         echo "command options are lsof, nc, bash's /dev/tcp, or python (or python3) with socket lib."
         return 127
      fi
      sleep 0.5
    done
    return 1
  }
  export -f wait_until_port_used

  # Generate random alphanumeric password with $1 (default: 8) characters
  create_passwd () {
    tr -cd 'a-zA-Z0-9' < /dev/urandom 2> /dev/null | head -c${1:-8}
  }
  export -f create_passwd
}
export -f source_helpers

source_helpers

# Set host of current machine
host=$(hostname)

# Setup one-time use passwords and initialize the VNC password
function change_passwd () {
  echo "Setting VNC password..."
  password=$(create_passwd "8")
  spassword=${spassword:-$(create_passwd "8")}
  (
    umask 077
    echo -ne "${password}\n${spassword}" | vncpasswd -f > "vnc.passwd"
  )
}
change_passwd

# Start up vnc server (if at first you don't succeed, try, try again)
echo "Starting VNC server..."
for i in $(seq 1 10); do
  # Clean up any old VNC sessions that weren't cleaned before
  vncserver -list | awk '/^:/{system("kill -0 "$2" 2>/dev/null || vncserver -kill "$1)}'

  # for turbovnc 3.0 compatability.
  if timeout 2 vncserver --help 2>&1 | grep 'nohttpd' >/dev/null 2>&1; then
    HTTPD_OPT='-nohttpd'
  fi

  # Attempt to start VNC server
  VNC_OUT=$(vncserver -log "vnc.log" -rfbauth "vnc.passwd" $HTTPD_OPT -noxstartup -geometry 800x600  2>&1)
  VNC_PID=$(pgrep -s 0 Xvnc) # the script above will daemonize the Xvnc process
  echo "${VNC_OUT}"

  # Sometimes Xvnc hangs if it fails to find working disaply, we
  # should kill it and try again
  kill -0 ${VNC_PID} 2>/dev/null && [[ "${VNC_OUT}" =~ "Fatal server error" ]] && kill -TERM ${VNC_PID}

  # Check that Xvnc process is running, if not assume it died and
  # wait some random period of time before restarting
  kill -0 ${VNC_PID} 2>/dev/null || sleep 0.$(random_number 1 9)s

  # If running, then all is well and break out of loop
  kill -0 ${VNC_PID} 2>/dev/null && break
done

# If we fail to start it after so many tries, then just give up
kill -0 ${VNC_PID} 2>/dev/null || clean_up 1

# Parse output for ports used
display=$(echo "${VNC_OUT}" | awk -F':' '/^Desktop/{print $NF}')
port=$((5900+display))

echo "Successfully started VNC server on ${host}:${port}..."

[[ -e "${SESSION_DIR}/before.sh" ]] && source "${SESSION_DIR}/before.sh"


echo "Script starting..."
DISPLAY=:${display} "${SESSION_DIR}/script.sh" &
SCRIPT_PID=$!

[[ -e "${SESSION_DIR}/after.sh" ]] && source "${SESSION_DIR}/after.sh"

# launches websockify in the background; waiting until the process
# has started proxying successfully.
start_websockify() {
  local log_file="./websockify.log"
  # launch websockify in background and redirect all output to a file.
  ${WEBSOCKIFY_CMD:-/opt/websockify/run} $1 --heartbeat=${WEBSOCKIFY_HEARTBEAT_SECONDS:-30} $2 &> $log_file &
  local ws_pid=$!
  local counter=0

  # wait till websockify has successfully started
  echo "[websockify]: pid: $ws_pid (proxying $1 ==> $2)" >&2
  echo "[websockify]: log file: $log_file" >&2
  echo "[websockify]: waiting ..." >&2
  until grep -q -i "proxying from :$1" $log_file
  do
    if ! ps $ws_pid > /dev/null; then
      echo "[websockify]: failed to launch!" >&2
      return 1
    elif [ $counter -ge 5 ]; then
      # timeout after ~5 seconds
      echo "[websockify]: timed-out :(!" >&2
      return 1
    else
      sleep 1
      ((counter=counter+1))
    fi
  done
  echo "[websockify]: started successfully (proxying $1 ==> $2)" >&2
  echo $ws_pid
  return 0
}

# Launch websockify websocket server
echo "Starting websocket server..."
websocket=$(find_port)
[ $? -eq 0 ] || clean_up 1 # give up if port not found

ws_pid=$(start_websockify ${websocket} localhost:${port})
[ $? -eq 0 ] || clean_up 1 # give up if websockify launch failed

# Set up background process that scans the log file for successful
# connections by users, and change the password after every
# connection
#echo "Scanning VNC log file for user authentications..."
#while read -r line; do
#  if [[ ${line} =~ "Full-control authentication enabled for" ]]; then
#    change_passwd
#    create_yml
#  fi
#done < <(tail -f --pid=${SCRIPT_PID} "vnc.log") &


# Create the connection yaml file
create_yml

# Wait for script process to finish
wait ${SCRIPT_PID} || clean_up 1

# Exit cleanly
clean_up
