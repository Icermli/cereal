#!/bin/bash

deploy_type="mainnet"
deploy_file_update="yes" # yes: bash will send files from local to server
deploy_status="run" # stop or run
node_address=""
node_pem="*.pem"
artifact_file_path=""
config_file_path=""

java_version_old="1.8"
java_version_new="1.9"

server_name="ubuntu"
server_disk_dir="/home/$server_name/ssd"
server_disk_device="/dev"
server_project_dir="/home/$server_name/ssd/v-systems-main"
server_log_file="node.log"

communication_port="9921 9922 9923 9928 9929"
rest_api_port="9922"
deploy_height_test_wait_time=15
deploy_height_test_number=3
deploy_wait_check_time=15

function mount_server {
  local key=$1
  local server=$2
  local server_name=$3
  local disk_dir=$4
  local disk_dev=$5

  ssh -i "$key" "$server" "
  #!/bin/bash
  mkdir -p $disk_dir
  device_name=\$(lsblk --sort SIZE | tail -1 | awk '{print \$1}')
  disk_device=\"$disk_dev/\$device_name\"
  entry=\"\$disk_device\t$disk_dir\text4\tdefaults\t0 0\"

  if mountpoint -q \"$disk_dir\"; then
    echo \"Disk has already mounted\"
  else
    echo \"To mount the disk of server (\"$server\")\"
    sudo mkfs.ext4 \$disk_device
    sudo mount \$disk_device $disk_dir
    sudo chown $server_name:$server_name $disk_dir
    echo -e \$entry | sudo tee -a /etc/fstab
  fi
  "
}

function deploy_vsys_to_server {
  local key=$1
  local server=$2
  local dir=$3
  local log_file=$4

  local wait_time=10

  echo "To deploy vsys in $server; Start..."
  ssh -i "$key" "$server" "
  #!/bin/bash
  if [ ! -d \"$dir\" ]; then
    echo \" > The given directory (\"$dir\") does not exist! Exit!\"
    exit
  else
    target_file=\$(echo $dir/*.jar)
    if [ ! -f \"\$target_file\" ]; then
      echo \" > The target file does not exist in the directory (\"$dir\")! Exit!\"
      exit
    fi
    config_file=\$(echo $dir/*.conf)
    if [ ! -f \"\$config_file\" ]; then
      echo \" > The config file does not exist in the directory (\"$dir\")! Exit!\"
      exit
    fi
  fi

  cd ssd/v-systems-main/

  number_files=\$(ls -A | wc -l)
  shopt -s extglob
  if [ \$number_files -gt 2 ]; then
    rm -r !(*.jar|*.conf)
  fi

  nohup java -jar \$target_file \$config_file > ./$log_file &
  echo \" > Deploy command has been run!\"
  "
}

function kill_old_process_by_port {
  local key=$1
  local server=$2
  local port=$3

  echo "To kill old process from port ($port) in $server; Start..."
  ssh -i "$key" "$server" "
  #!/bin/bash
  for i in $port
  do
    echo \" > Checking progress on port \$i\"
    pid_str=\$(sudo netstat -ltnp | grep -w \":\$i\"| awk '{print \$7}')
    if [ -z \$pid_str ]; then
      echo \" > > The port \$i does not in any process\"
    else
      echo \" > > pid string is \$pid_str\"
    fi
    if [ ! -z \$pid_str ]; then
        IFS='/' read -r -a temp_array <<< \$pid_str
        pid=\$temp_array
        echo \" > > To kill pid: \$pid\"
        if [ ! -z \$pid ]; then
          sudo kill -9 \$pid
          while sudo kill -0 \$pid; do
              sleep 1
          done
        fi
    fi
  done
  "
  echo " > All port checked! Kill done!"
}

function check_update_server_JRE {
  local key=$1
  local server=$2
  local old_version=$3
  local new_version=$4

  echo "To check java in $server (between $old_version and $new_version); Start..."
  ssh -i "$key" "$server" "
  #!/bin/bash
  flag=0
  if type -p java; then
      echo \" > Found java executable in $server\"
      _java=java
  elif [[ -n \"\$JAVA_HOME\" ]] && [[ -x \"\$JAVA_HOME/bin/java\" ]]; then
      echo \" > Found java executable in JAVA_HOME\"
      _java=\"\$JAVA_HOME/bin/java\"
  else
      echo \" > No JDK 8 in $server\"
      flag=1
  fi
  if [[ \"\$_java\" ]]; then
    version=\$(\"\$_java\" -version 2>&1 | awk -F '\"' '/version/ {print \$2}')
    echo \" > Java version: \$version\"

    if [[ ! \"\$version\" <  $old_version ]] && [[ \"\$version\" < $new_version ]]; then
        echo \" > JDK is 1.8, no update needed\"
    else
        echo \" > JDK is not suitable, reinstall openJDK 8...\"
        printf 'Y' | sudo apt-get remove openJDK*
        flag=1
    fi
  fi

  if [ \"\$flag\" -eq 1 ]; then
      echo \" > Server ($server) is installing JDK 8...\"
      printf '\n' | sudo add-apt-repository ppa:openjdk-r/ppa
      sudo apt-get update
      printf 'Y' | sudo apt-get install openjdk-8-jdk
  fi
  "
}

function check_server_folder_clean {
  local key=$1
  local server=$2
  local folder=$3

  ssh -i "$key" "$server" "
  #!/bin/bash
  mkdir -p "$folder"
  if [ \"\$(ls -A $folder)\" ]; then
    echo \"Detect files in the server (\"$server\") for the directory (\"$folder\")\"
    echo \" > Clear all files and subfolders...\"
    rm -r "$folder/*"
  fi
  "
}

function check_server_data_folder_clean {
  local key=$1
  local server=$2
  local config=$3

  local folder="$(grep 'directory' $config | sed 's/[ \t]*directory[ ]*=[ ]*//')"
  echo $folder

  ssh -i "$key" "$server" "
  #!/bin/bash
  mkdir -p "$folder"
  if [ \"\$(ls -A $folder)\" ]; then
    echo \"Detect files in the server (\"$server\") for the directory (\"$folder\")\"
    echo \" > Clear all files and subfolders...\"
    rm -r "$folder/*"
  fi
  "
}

function send_file_to_server {
  local key=$1
  local server=$2
  local target_file=$3
  local server_dir=$4
  local name=$5

  echo "To send local $name file to the server ($server) by the directory ($server_dir)..."
  scp -i "$key" "$target_file" "$server:$server_dir"
  ssh -i "$key" "$server" "chmod -R 700 $server_dir"
}

function fetch_local_file {
  local file=$1
  local name=$2

  if [[ -f $file ]]; then
    echo "Fetch the $name local file by" $file
  else
    echo "Error: The $name local file does not exist! Exit!"
    exit
  fi
}

function json_extract {
  local key=$1
  local json=$2

  local string_regex='"([^"\]|\\.)*"'
  local number_regex='-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?'
  local value_regex="${string_regex}|${number_regex}|true|false|null"
  local pair_regex="\"${key}\"[[:space:]]*:[[:space:]]*(${value_regex})"

  if [[ ${json} =~ ${pair_regex} ]]; then
    local result=$(sed 's/^"\|"$//g' <<< "${BASH_REMATCH[1]}")
    echo $result
  else
    return 0
  fi
}

function height_comparison {
  local height_max=$1
  local height_current=$2
  local change_time=$3

  if [[ $(( $height_max - $height_current )) -ge 0 ]]; then
    echo $height_max $change_time
  else
    echo $height_current $(( $change_time + 1 ))
  fi
}

echo "======================= prepare to deploy in server $node_address ======================="

# Read 
while true; do
  read -p "Do you wish to run or stop remote server? " yn
  case $yn in
    [Rr]* ) deploy_status="run"; break;;
    [Ss]* ) deploy_status="stop"; break;;
    * ) echo "Please answer [r]un or [s]top.";;
  esac
done

if [[ $deploy_status == "stop" ]]; then
  read -p "Please input ip address: " node_address
  read -p "Please input ssh key path: " node_pem_path
  kill_old_process_by_port "$node_pem_path" \
  "$server_name@$node_address" "$communication_port"
  exit
fi

# Read 
while true; do
  read -p "Do you wish to update files to remote server? " yn
  case $yn in
    [Yy]* ) file_update="yes"; break;;
    [Nn]* ) file_update="no"; break;;
    * ) echo "Please answer [y]es or [n]o.";;
  esac
done

if [[ $file_update == "yes" ]]; then
  read -p "Please input jar file path: " jar_file_path
  read -p "Please input config file path: " conf_file_path
fi

# Read 
read -p "Please input ip address: " node_address

# Read
read -p "Please input ssh key path: " node_pem_path


fetch_local_file "$node_pem_path" "pem"
chmod 400 "$node_pem_path"

mount_server "$node_pem_path" "$server_name@$node_address" \
"$server_name" "$server_disk_dir" "$server_disk_device"

if [[ "$file_update" == "yes" ]]; then
  echo "The path of the jar file is" $jar_file_path
  echo "The path of the config file is" $conf_file_path
  fetch_local_file "$jar_file_path" "target"
  fetch_local_file "$conf_file_path" "config"
  while true; do
  	read -p "Do you wish to clean data? " yn
  	case $yn in
  	  [Yy]* ) clean_data="yes"; break;;
      [Nn]* ) clean_data="no"; break;;
      * ) echo "Please answer [y]es or [n]o.";;
  	esac
  done
  check_server_folder_clean "$node_pem_path" \
  "$server_name@$node_address" "$server_project_dir"
  send_file_to_server "$node_pem_path" "$server_name@$node_address" \
  "$(echo $jar_file_path)" "$server_project_dir" "target"
  send_file_to_server "$node_pem_path" "$server_name@$node_address" \
  "$(echo $conf_file_path)" "$server_project_dir" "config"
fi

echo "The deploy server is $node_address and finally it will $deploy_status!"
echo " > The node address for deploy is $node_address"
echo " > The project folder in local machine is $jar_file_path"

check_update_server_JRE "$node_pem_path" \
"$server_name@$node_address" "$java_version_old" "$java_version_new"

echo "======================= start to deploy with height check $deploy_height_test_number times ======================="

kill_old_process_by_port "$node_pem_path" \
"$server_name@$node_address" "$communication_port"

if [[ "$clean_data" == "yes" ]]; then
  check_server_data_folder_clean "$node_pem_path" \
  "$server_name@$node_address" "$(echo $conf_file_path)"
fi

deploy_vsys_to_server "$node_pem_path" \
"$server_name@$node_address" "$server_project_dir" "$server_log_file"

echo "To test the HEIGHT of blockchain in $node_address"
rest_api_address="$node_address:$rest_api_port"
echo " > Rest API is through" $rest_api_address

sleep ${deploy_wait_check_time}

height_max=0
change_time=0
height=0
for (( i=1; i<=$deploy_height_test_number; i++))
do

  result=$(curl -X GET --header 'Accept: application/json' -s "$rest_api_address/blocks/height")
  height=$(json_extract "height" "$result")

  if [[ -n "$height" ]]; then
    echo " > The height for the blockchain in the $i-th check is: $height"
    read height_max change_time < <(height_comparison "$height_max" "$height" "$change_time")
  else
    echo " > The height for the blockchain in the \"$i\"-th check is: empty"
  fi

  sleep $deploy_height_test_wait_time

done

if [[ $change_time -gt 1 ]]; then
  node_status="Normal"
else
  node_status="Abnormal"
fi

if [[ "$node_status" == "Normal" ]]; then
  echo " > Max height of the blockchain is: $height_max"
  echo "The status of the blockchain is: $node_status ($(( change_time - 1 )) times with height change out of $deploy_height_test_number checks)"
  echo "Successful to deploy! Bash file finished!"
  echo "========================================================================================="
else
  echo " > Max height of the blockchain is: $height_max"
  echo "The status of the blockchain is: $node_status"
  echo "Fail to deploy! Bash file finished!"
  echo "========================================================================================="
fi

