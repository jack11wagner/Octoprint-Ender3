#!/bin/bash

########## Basic Settings ##########
DOMAIN=cslab.moravian.edu
STATUS_API_KEY=3DE4DE53DE4DE5
OCTOPRINT_USERNAME=octoprint
OCTOPRINT_PASSWORD=cslab
USB_DEV_SUFFIX="-PRINTER"

COLOR_LIST=(red orange green blue violet)
size=${#COLOR_LIST[@]}


FULL_HOSTNAME="$(hostname -s).$DOMAIN"

index=$(hostname | awk '{print substr($0,length($0))}')-1
RANDOM_COLOR="${COLOR_LIST[$index]}"

UDEV_RULES_FILE="/etc/udev/rules.d/99-usb.rules"
NGINX_CONFIG="/etc/nginx/sites-available/octoprint"
CAM_CONFIG_0="/boot/octopi.txt"
CAM_CONFIG_D="/boot/octopi.conf.d"
PIP="$HOME/oprint/bin/pip"
PIP_OPTS="-q --disable-pip-version-check"


########## Functions ##########
uppercase() { echo "$1" | tr "[:lower:]" "[:upper:]"; }
lowercase() { echo "$1" | tr "[:upper:]" "[:lower:]"; }
yes_no() {
    local yn=''
    while true; do
        read -p "$1 " yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}
add_usb_device() {
    local NAME="$1"
    local DEV_NAME="$2"
    local SUBSYS="$3"

    # Get the USB device info (once they plug it in)
    echo "Now plug in $NAME to this Pi"
    USB_INFO="$(tail -n0 -f /var/log/messages | grep -m1 -A1 "New USB device found" --binary-files=text)"
    VENDOR="$(echo "$USB_INFO" | grep -o 'idVendor=[0-9a-f]\{4\}' | grep -m1 -o '[0-9a-f]\{4\}')"
    PRODUCT="$(echo "$USB_INFO" | grep -o 'idProduct=[0-9a-f]\{4\}' | grep -m1 -o '[0-9a-f]\{4\}')"
    DEVPATH="$(echo "$USB_INFO" | grep -o 'usb [0-9]\+-[0-9]\+\.[0-9]\+' | grep -m1 -o '[0-9]\+\.[0-9]\+')"
    SERIAL="$(echo "$USB_INFO" | grep -o 'SerialNumber=[^ ,]\+' | grep -m1 -o '[0-9]\+\.[0-9]\+')"

    # Add the info to the USB dev rules
    if [ "$SERIAL" = 0 ] || [ -z "$SERIAL" ]; then

        echo "Adding $DEV_NAME as USB device $VENDOR:$PRODUCT on USB port $DEVPATH (it must stay on that port)"
        RULE_ATTR="ATTRS{devpath}==\"$DEVPATH\""
    else
        RULE_ATTR="ATTRS{serial}==\"$SERIAL\""
        echo "Adding $DEV_NAME as USB device $VENDOR:$PRODUCT with serial number $SERIAL"
    fi
    sudo tee -a "$UDEV_RULES_FILE" >/dev/null <<EOF
SUBSYSTEM=="$SUBSYS", ATTRS{idVendor}=="$VENDOR", ATTRS{idProduct}=="$PRODUCT", $RULE_ATTR, SYMLINK+="$DEV_NAME"
EOF
}


########## Shutdown services ##########
# We will start them as necessary later but when modifying settings best to be stopped
sudo systemctl stop nginx
sudo systemctl stop webcamd
sudo systemctl stop "octoprint*"
sudo systemctl stop haproxy
sudo systemctl disable haproxy


########## Check for current setup ##########
SKIP_INITIAL_SETUP=false
if [ -s "$UDEV_RULES_FILE" ]; then
    # Already partially set up, ask to reset or continue
    # Need to make variables NAMES and CAM_PORTS
    readarray -t NAMES <<<"$(grep 'SUBSYSTEM=="tty"' "$UDEV_RULES_FILE" | grep -o 'SYMLINK+="[^"]\+'"$USB_DEV_SUFFIX"'"' | cut -c11- | sed 's/'"$USB_DEV_SUFFIX"'"$//')"
    COUNT="${#NAMES[@]}"
    CAM_PORTS=()
    if ! grep "^camera_usb_options" /boot/octopi.txt &>/dev/null; then  # if no camera was setup
        for I in "${!NAMES[@]}"; do CAM_PORTS+=(""); done
    elif [ "$(ls "$CAM_CONFIG_D"/camera*.txt 2>/dev/null | wc -l)" -eq $((COUNT-1)) ]; then  # if all printers have a camera
        readarray -t CAM_PORTS <<<"$(seq 8080 $((8080+COUNT-1)))"
    else # some cameras are missing - assume that webcam:snapshot is setup in each config
        for CONFIG in "$HOME"/.octoprint/config.yaml "$HOME"/.octoprint?/config.yaml; do
            CAM_PORTS+=("$(sed -E -n '/^webcam:/,/^[^ ]/p' "$CONFIG" | grep ' snapshot:' | grep -o ':80[0-9]\{2\}/' | cut -c2-5)")
        done
    fi
    # Ask the user
    echo "The following printers are setup on this machine already:"
    for I in "${!NAMES[@]}"; do
        echo -n "  ${NAMES[$I]} with "
        [ -z "${CAM_PORTS[$I]}" ] && echo "no camera" || echo "camera on port ${CAM_PORTS[$I]}"
    done
    if yes_no "Would you like to reset (erase) this and start over? (otherwise attempt to merge new settings)"; then
        sudo truncate -s 0 "$UDEV_RULES_FILE"
        sudo sed -i 's@^camera=.*@#\0@' "$CAM_CONFIG_0"
        sudo sed -i 's@^camera_usb_options=.*@#\0@' "$CAM_CONFIG_0"
        sudo sed -i 's@^camera_http_options=.*@#\0@' "$CAM_CONFIG_0"
        sudo rm -f "$CAM_CONFIG_D"/camera*.txt
    else
        SKIP_INITIAL_SETUP=true
    fi
fi


########## Printers and their cameras ##########
if ! $SKIP_INITIAL_SETUP; then
    NAMES=()
    CAM_PORTS=()
    CAM_PORT=8080
    NUM_CAMS=0
    read -p "What is the first printer name? " NAME
    while [ -n "$NAME" ]; do
        NAMES+=("$NAME")
        NAME="$(uppercase "$NAME")"

        # Add the printer's USB info
        # This will cause there to be symlinks /dev/$NAME$USB_DEV_SUFFIX -> /dev/ttyUSB#
        add_usb_device "$NAME" "$NAME$USB_DEV_SUFFIX" "tty"

        # Get the camera for this printer
        if yes_no "Does this printer have a camera?"; then
            #add_usb_device "the camera for $NAME" "$NAME-CAMERA" "video4linux"  # cannot use this since webcamd script only looks for /dev/video* and /dev/v4l/* devices
            echo "Now plug in the camera for $NAME to this Pi"
            USB_INFO="$(tail -n0 -f /var/log/messages | grep -m1 -A1 "New USB device found" --binary-files=text)"
            DEVPATH="$(echo "$USB_INFO" | grep -o 'usb [0-9]\+-[0-9]\+\.[0-9]\+' | grep -m1 -o '[0-9]\+\.[0-9]\+')"
            # This assumes the that first one is what we want
            # With the HP cameras that we have, index0 is the video stream while index1 is the metadata stream
            # Don't know if that will generally be true
            sleep 0.5s
            V4LPATH="$(ls /dev/v4l/by-path/*-usb-*:"$DEVPATH":* | head -n 1)"
            if [ "$NUM_CAMS" -eq 0 ]; then
                sudo sed -i 's@^#\?camera=.*@camera="usb"@' "$CAM_CONFIG_0"
                sudo sed -i 's@^#\?camera_usb_options=.*@camera_usb_options="-d '"$V4LPATH"' -r 640x480 -f 10"@' "$CAM_CONFIG_0"
                sudo sed -i 's@^#\?camera_http_options=.*@camera_http_options="-n --port '$CAM_PORT'"@' "$CAM_CONFIG_0"
            else
                # To enable additional cameras, all we have to do is create another config file in the correct location
                # Weird, but it works. We also make sure to specify exact options to fix to specific devices.
                sudo mkdir -p "$CAM_CONFIG_D"
                sudo tee "$CAM_CONFIG_D/camera$NUM_CAMS.txt" >/dev/null <<EOF
# Creates an additional camera stream
# See $CAM_CONFIG_0 for more information on these values
camera="usb"
camera_usb_options="-d $V4LPATH -r 640x480 -f 10"
camera_http_options="-n --port $CAM_PORT"
EOF
            fi
            CAM_PORTS+=("$CAM_PORT")
            ((NUM_CAMS+=1))
            ((CAM_PORT+=1))
        else
            CAM_PORTS+=("")
        fi

        # Get the next printer
        read -p "What is the next printer name (or blank to be done)? " NAME
    done

    # Reload the udev rules
    sudo udevadm control --reload
fi

# Start the camera service
sudo systemctl enable webcamd
sudo systemctl start webcamd


########## NGINX ##########
echo "Setting up nginx..."
echo "  The eth0 MAC address is $(ifconfig | grep -A 8 eth0 | grep -o '[0-9a-f]\{2\}\(:[0-9a-f]\{2\}\)\{5\}')"
#echo "  The wlan0 MAC address is $(ifconfig | grep -A 8 wlan0 | grep -o '[0-9a-f]\{2\}\(:[0-9a-f]\{2\}\)\{5\}')"
sudo tee "$NGINX_CONFIG" >/dev/null <<EOF
# Map domain names to specific instances of octoprint on different ports
EOF
WEB_PORT=5000
WEB_PORTS=()
for NAME in "${NAMES[@]}"; do
    NAME="$(lowercase "$NAME")"
    WEB_PORTS+=("$WEB_PORT")
    echo "  Mapping http://$FULL_HOSTNAME:$WEB_PORT/ to http://$NAME.$DOMAIN/"
    sudo tee -a "$NGINX_CONFIG" >/dev/null <<EOF
server {
    listen 80;
    server_name $NAME.$DOMAIN;
    client_max_body_size 16m;
    location / {
        proxy_pass http://localhost:$WEB_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    ((WEB_PORT+=1))
done

# Update the sites which are enabled
pushd /etc/nginx/sites-enabled >/dev/null || exit
sudo rm -f default  # this streams HLS video and conflicts with a few things
sudo ln -fs ../sites-available/octoprint
popd >/dev/null || exit

# Update the configuration
sudo sed -i 's/^ConditionPathExists/#ConditionPathExists/' /lib/systemd/system/nginx.service
sudo sed -i 's/^Description=.*$/Description=NGINX server/' /lib/systemd/system/nginx.service
sudo sed -i 's/#\s\+server_names_hash_bucket_size/server_names_hash_bucket_size/' /etc/nginx/nginx.conf

# Start the NGINX service
sudo systemctl daemon-reload
sudo systemctl enable nginx
sudo systemctl start nginx


##### Install yq #####
# I believe it is actually already installed, so we skip this usually
if ! which yq &>/dev/null; then
    echo "Installing yq..."
    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm
    sudo chmod a+x /usr/local/bin/yq
fi


##### Install plugins #####
echo "Installing plugins..."
echo "Installing Themeify..."
"$PIP" install $PIP_OPTS "https://github.com/birkbjo/OctoPrint-Themeify/archive/master.zip"

echo "Installing Octolapse..."
"$PIP" install $PIP_OPTS "https://github.com/FormerLurker/Octolapse/archive/master.zip"

echo "Configuring appropriate settings for Octolapse plugin..."

touch "$HOME/.octoprint/data/octolapse/settings.json"
wget -O "$HOME/.octoprint/data/octolapse/settings.json" "https://drive.google.com/u/0/uc?id=1BJ26tj5cMtgI--XPT1jMcEZS0uQ6H3cU&export=download&confirm=t"

touch "$HOME/.octoprint2/data/octolapse/settings.json"
wget -O "$HOME/.octoprint2/data/octolapse/settings.json" "https://drive.google.com/u/0/uc?id=1BJ26tj5cMtgI--XPT1jMcEZS0uQ6H3cU&export=download&confirm=t"

##### Update .octoprint config #####
echo "Updating config.yaml with our defaults..."
yq -i eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$HOME/.octoprint/config.yaml" - <<EOF
api:
  allowCrossOrigin: true
feature:
  sdSupport: false
plugins:
  themeify:
    customRules:
    - enabled: false
      rule: background-color
      selector: .navbar-inner
      value: '#2f3136'
    - enabled: false
      rule: background-color
      selector: .accordion
      value: '#2f3136'
    - enabled: true
      rule: ''
      selector: ''
      value: ''
    - enabled: true
      rule: ''
      selector: ''
      value: ''
    enableCustomization: true
    tabs:
      enableIcons: true
      icons:
      - domId: '#temp_link'
        enabled: true
        faIcon: fa fa-line-chart
      - domId: '#control_link'
        enabled: true
        faIcon: fa fa-gamepad
      - domId: '#gcode_link'
        enabled: true
        faIcon: fa fa-object-ungroup
      - domId: '#term_link'
        enabled: true
        faIcon: fa fa-terminal
  octolapse:
    _config_version: 3
server:
  firstRun: false
  host: 0.0.0.0
  onlineCheck:
    enabled: true
    host: 8.8.8.8
  pluginBlacklist:
    enabled: true
temperature:
  profiles:
  - bed: 80
    chamber: null
    extruder: 240
    name: ABS
  - bed: 70
    chamber: null
    extruder: 240
    name: PETG
  - bed: 50
    chamber: null
    extruder: 200
    name: PLA
webcam:
  flipH: true
  flipV: true
  rotate90: true
EOF


echo "Adding users to users.yaml..."
USER_YAML="$(cat << EOF
$OCTOPRINT_USERNAME:
  active: true
  apikey: null
  groups:
  - users
  - admins
  password: X
  permissions: []
  roles:
  - user
  - admin
  settings: {}
status:
  active: true
  apikey: $STATUS_API_KEY
  groups:
  - readonly
  password: X
  permissions: []
  roles:
  - user
  settings: {}
EOF
)"
if [ -s "$HOME/.octoprint/users.yaml" ]; then
yq -i eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$HOME/.octoprint/users.yaml" - <<<"$USER_YAML"
else
cat >"$HOME/.octoprint/users.yaml" <<<"$USER_YAML"
fi

echo "Updating the default profile with Ender 3 settings..."
yq -i eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$HOME/.octoprint/printerProfiles/_default.profile" - <<EOF
extruder:
  count: 1
  defaultExtrusionLength: 5
  nozzleDiameter: 0.4
heatedBed: true
heatedChamber: false
id: _default
model: Ender 3
name: Ender 3
volume:
  custom_box: false
  depth: 220.0
  formFactor: rectangular
  height: 250.0
  origin: lowerleft
  width: 220.0
EOF


##### Create copies for each octoprint service #####
echo "Copying configuration and service..."
CONF_DIRS=("$HOME/.octoprint")
SERVICES=("octoprint")
NUM=2
for NAME in "${NAMES[@]:1}"; do
    DIR="$HOME/.octoprint$NUM"
    SERVICE="octoprint$NUM"
    CONF_DIRS+=("$DIR")
    SERVICES+=("$SERVICE")
    rm -rf "$DIR"
    cp -R "$HOME/.octoprint" "$DIR"
    sed 's~^ExecStart=.*$~& --basedir='"$DIR"'~' /etc/systemd/system/octoprint.service | \
        sudo tee /etc/systemd/system/$SERVICE.service >/dev/null
    sudo systemctl enable $SERVICE
    ((NUM+=1))
done


########## Update unique settings per instance ##########
for I in "${!NAMES[@]}"; do
    NAME="$(uppercase "${NAMES[I]}")"
    echo "Setting the unique settings for $(lowercase "$NAME")..."
    DIR="${CONF_DIRS[I]}"
    WEB_PORT="${WEB_PORTS[I]}"
    CAM_PORT="${CAM_PORTS[I]}"
    if [ -z "$CAM_PORT" ]; then
        SNAPSHOT_URL="null"
        STREAM_URL="null"
    else
        SNAPSHOT_URL="http://$FULL_HOSTNAME:$CAM_PORT/?action=snapshot"
        STREAM_URL="http://$FULL_HOSTNAME:$CAM_PORT/?action=stream"
    fi
    APIKEY="$(hexdump -vn16 -e'4/4 "%08X" 1 "\n"' /dev/urandom)"  # random 32 digit hex string
    UUID_1="$(cat /proc/sys/kernel/random/uuid)"
    UUID_2="$(cat /proc/sys/kernel/random/uuid)"

    # Note: "accessControl:salt" and "server:secretKey" should auto-generate on first use
    yq -i eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$DIR/config.yaml" - <<EOF
api:
  key: $APIKEY
appearance:
  name: $NAME
  color: $RANDOM_COLOR
plugins:
  discovery:
    upnpUuid: $UUID_1
  errortracking:
    unique_id: $UUID_2
serial:
  additionalPorts:
  - /dev/$NAME$USB_DEV_SUFFIX
  autoconnect: true
  port: /dev/$NAME$USB_DEV_SUFFIX
server:
  port: $WEB_PORT
webcam:
  snapshot: $SNAPSHOT_URL
  stream: $STREAM_URL
EOF
    # encrypt the password with the unique salt
    ./oprint/bin/octoprint user password "$OCTOPRINT_USERNAME" --password "$OCTOPRINT_PASSWORD"
done


########## Start the OctoPrint Services ##########
echo "Starting the OctoPrint services..."
sudo systemctl daemon-reload
for SERVICE in "${SERVICES[@]}"; do
    sudo systemctl start "$SERVICE"
done
