#!/bin/bash

#all operations must be with root/sudo
if (($EUID != 0)); then
    echo "Please run with sudo"
    exit
fi

#this is a weak check, but will catch most cases
if [ $SUDO_USER ]; then
    user=$SUDO_USER
else
    echo "You should not run this script as root. Use sudo as a normal user"
    exit
fi

if [ "$user" == root ]; then
    echo "You should not run this script as root. Use sudo as a normal user"
    exit
fi

SCRIPTDIR=$(dirname $(readlink -f $0))
source $SCRIPTDIR/plugins.sh

# from stackoverflow.com/questions/3231804
prompt_confirm() {
    while true; do
        read -r -n 1 -p "${1:-Continue?} [y/n]: " REPLY
        case $REPLY in
            [yY])
                echo
                return 0
            ;;
            [nN])
                echo
                return 1
            ;;
            *) printf " \033[31m %s \n\033[0m" "invalid input" ;;
        esac
    done
}

get_settings() {
    #Get octoprint_deploy settings, all of which are written on system prepare
    if [ -f /etc/octoprint_deploy ]; then
        TYPE=$(cat /etc/octoprint_deploy | sed -n -e 's/^type: \(\.*\)/\1/p')
        STREAMER=$(cat /etc/octoprint_deploy | sed -n -e 's/^streamer: \(\.*\)/\1/p')
        HAPROXY=$(cat /etc/octoprint_deploy | sed -n -e 's/^haproxy: \(\.*\)/\1/p')
    fi
    OCTOEXEC="sudo -u $user /home/$user/OctoPrint/bin/octoprint"
    OCTOCONFIG="/home/$user"
}

#https://askubuntu.com/questions/39497
deb_packages() {
    #All extra packages needed can be added here for deb based systems. Only available will be selected.
    apt-cache --generate pkgnames |
    grep --line-regexp --fixed-strings \
    -e make \
    -e curl \
    -e v4l-utils \
    -e python-is-python3 \
    -e python3-venv \
    -e python3.9-venv \
    -e python3.10-venv \
    -e python3-setuptools \
    -e virtualenv \
    -e python3-dev \
    -e build-essential \
    -e python3-setuptools \
    -e libyaml-dev \
    -e python3-pip \
    -e cmake \
    -e libjpeg8-dev \
    -e libjpeg62-turbo-dev \
    -e gcc \
    -e g++ \
    -e libevent-dev \
    -e libjpeg-dev \
    -e libbsd-dev \
    -e ffmpeg \
    -e chromium\
    -e chromium-browser\
    -e uuid-runtime -e ssh -e libffi-dev -e haproxy -e ssl-cert | xargs apt-get install -y
    
    #pacakges to REMOVE go here
    apt-cache --generate pkgnames |
    grep --line-regexp --fixed-strings \
    -e brltty |
    xargs apt-get remove -y
    
    install_chromium
}

install_chromium(){
   chromium_browser_package=$(apt search chromium-browser | grep -o "chromium-browser.*")
    if [ -n "$chromium_browser_package" ]; then
        echo "Chromium browser package found: $chromium_browser_package" | log
        # Install Chromium browser
        sudo apt install -y chromium-browser
    else
            chromium=$(apt search chromium | grep -o "chromium.*")
        if [ -n "$chromium" ]; then
            echo "Chromium package found: $chromium" | log
            # Install Chromium 
            sudo apt install -y chromium
        else
            echo "Neither chromium-browser nor chromium is available via apt." | log
        fi
    fi
}

prepare() {
    echo
    echo
    PS3='OS type: '
    options=("Ubuntu 20-22, Mint, Debian, Raspberry Pi OS" "Fedora/CentOS" "ArchLinux" "Quit")
    select opt in "${options[@]}"; do
        case $opt in
            "Ubuntu 20-22, Mint, Debian, Raspberry Pi OS")
                INSTALL=2
                break
            ;;
            "Fedora/CentOS")
                INSTALL=3
                break
            ;;
            "ArchLinux")
                INSTALL=4
                break
            ;;
            "Quit")
                exit 1
            ;;
            *) echo "invalid option $REPLY" ;;
        esac
    done
    
    echo
    echo
    if prompt_confirm "Ready to begin?"; then
        #remove streamer directories, if they exist
        remove_everything
        
        echo 'Adding current user to dialout and video groups.'
        usermod -a -G dialout,video $user
        
        if [ $INSTALL -gt 1 ]; then
            OCTOEXEC="sudo -u $user /home/$user/OctoPrint/bin/octoprint"
            OCTOPIP="sudo -u $user /home/$user/OctoPrint/bin/pip"
            echo "Adding systemctl and reboot to sudo"
            echo "$user ALL=NOPASSWD: /usr/bin/systemctl" >/etc/sudoers.d/octoprint_systemctl
            echo "$user ALL=NOPASSWD: /usr/sbin/reboot" >/etc/sudoers.d/octoprint_reboot
            echo "$user ALL=NOPASSWD: /usr/sbin/shutdown" >/etc/sudoers.d/octoprint_shutdown
            echo "This will install necessary packages, download and install OctoPrint on this machine."
            #install packages
            #All DEB based
            PYVERSION=${PYVERSION:-python3}
            if [ $INSTALL -eq 2 ]; then
                apt-get update >/dev/null
                deb_packages
            fi
            
            #Fedora35/CentOS
            if [ $INSTALL -eq 3 ]; then
                dnf -y install gcc python3-devel cmake libjpeg-turbo-devel libbsd-devel libevent-devel haproxy openssh openssh-server openssl libffi-devel
                systemctl enable sshd.service
                PYV=$(python3 -c"import sys; print(sys.version_info.minor)")
                if [ $PYV -eq 11 ]; then
                    dnf -y install python3.10-devel
                    PYVERSION=${PYVERSION:-python3.10}
                fi
            fi
            
            #ArchLinux
            if [ $INSTALL -eq 4 ]; then
                pacman -S --noconfirm make cmake python python-virtualenv libyaml python-pip libjpeg-turbo python-yaml python-setuptools libffi ffmpeg gcc libevent libbsd openssh haproxy v4l-utils
                usermod -a -G uucp $user
            fi
            
            echo "Enabling ssh server..."
            systemctl enable ssh.service
            echo "Installing OctoPrint virtual environment in /home/$user/OctoPrint"
            #make venv
            sudo -u $user $PYVERSION -m venv /home/$user/OctoPrint
            #update pip
            sudo -u $user /home/$user/OctoPrint/bin/pip install --upgrade pip
            #pre-install wheel
            sudo -u $user /home/$user/OctoPrint/bin/pip install wheel
            #install oprint
            sudo -u $user /home/$user/OctoPrint/bin/pip install OctoPrint
            #start server and run in background
            echo 'Creating OctoPrint service...'
            cat $SCRIPTDIR/octoprint_generic.service |
            sed -e "s/OCTOUSER/$user/" \
            -e "s#OCTOPATH#/home/$user/OctoPrint/bin/octoprint#" \
            -e "s#OCTOCONFIG#/home/$user/#" \
            -e "s/NEWINSTANCE/octoprint/" \
            -e "s/NEWPORT/5000/" >/etc/systemd/system/octoprint.service

            echo 'Installing Octoprint-NanoFactory' | log
            $OCTOPIP install "https://github.com/Printerverse/Octoprint-NanoFactory/archive/main.zip"
            echo

            systemctl stop haproxy
            systemctl disable haproxy
            
            echo
            echo
            echo
 
            streamer_install
            
            #Fedora has SELinux on by default (and is very annoying) so must make adjustments
            if [ $INSTALL -eq 3 ]; then
                semanage fcontext -a -t bin_t "/home/$user/OctoPrint/bin/.*"
                chcon -Rv -u system_u -t bin_t "/home/$user/OctoPrint/bin/"
                restorecon -R -v /home/$user/OctoPrint/bin
                
                if [ $VID -eq 1 ]; then
                    semanage fcontext -a -t bin_t "/home/$user/mjpg-streamer/.*"
                    chcon -Rv -u more sysystem_u -t bin_t "/home/$user/mjpg-streamer/"
                    restorecon -R -v /home/$user/mjpg-streamer
                fi
                if [ $VID -eq 2 ]; then
                    semanage fcontext -a -t bin_t "/home/$user/ustreamer/.*"
                    chcon -Rv -u system_u -t bin_t "/home/$user/ustreamer/"
                    restorecon -R -v /home/$user/ustreamer
                fi
                
            fi

            # Checking for existence of appkeys folder
            if [ ! -d "/home/$user/.octoprint/data" ]; then
                mkdir -p "/home/$user/.octoprint/data"
            fi
            if [ ! -d "/home/$user/.octoprint/data/appkeys" ]; then
                mkdir -p "/home/$user/.octoprint/data/appkeys"
            fi

            # copying config and keys to data folder
            cp -p $SCRIPTDIR/config.basic /home/$user/.octoprint/config.yaml
            cp -p $SCRIPTDIR/keys.basic /home/$user/.octoprint/data/appkeys/keys.yaml
            
            #Prompt for admin user and firstrun stuff
            install_yq
            firstrun
            initialize_nanofactory

            echo 'Starting OctoPrint service on port 5000'
            #server restart commands
            $OCTOEXEC config set server.commands.serverRestartCommand 'sudo systemctl restart octoprint'
            $OCTOEXEC config set server.commands.systemRestartCommand 'sudo reboot'
            $OCTOEXEC config set server.commands.systemShutdownCommand 'sudo shutdown now'
            $OCTOEXEC config set webcam.ffmpeg /usr/bin/ffmpeg
            systemctl start octoprint.service
            systemctl enable octoprint.service
            echo
            echo
            
            #this restart seems necessary in some cases
            systemctl restart octoprint.service
        fi
        touch /etc/camera_ports
        echo "System preparation complete!"
        
    fi
    main_menu
}

streamer_install() {
    PS3='Which video streamer you would like to install?: '
    options=("mjpeg-streamer" "ustreamer (recommended)" "None")
    select opt in "${options[@]}"
    do
        case $opt in
            "mjpeg-streamer")
                VID=1
                break
            ;;
            "ustreamer (recommended)")
                VID=2
                break
            ;;
            "None")
                VID=3
                break
            ;;
            *) echo "invalid option $REPLY";;
        esac
    done
    
    if [ $VID -eq 1 ]; then
        
        #install mjpg-streamer, not doing any error checking or anything
        echo 'Installing mjpeg-streamer'
        sudo -u $user git clone https://github.com/jacksonliam/mjpg-streamer.git mjpeg
        #apt -y install
        sudo -u $user make -C mjpeg/mjpg-streamer-experimental > /dev/null
        sudo -u $user mv mjpeg/mjpg-streamer-experimental /home/$user/mjpg-streamer
        sudo -u $user rm -rf mjpeg

        if [ -f "/home/$user/mjpg-streamer/mjpg_streamer" ]; then
            echo "mjpg_streamer installed successfully"
            echo 'streamer: mjpg-streamer' >> /etc/octoprint_deploy
        else
            echo "There was a problem installing the streamer. Please try again."
            streamer_install
        fi
    fi
    
    if [ $VID -eq 2 ]; then
        
        #install ustreamer
        sudo -u $user git clone --depth=1 https://github.com/pikvm/ustreamer
        sudo -u $user make -C ustreamer > /dev/null

        if [ -f "/home/$user/ustreamer/ustreamer" ]; then
            echo "ustreamer installed successfully"
            echo 'streamer: ustreamer' >> /etc/octoprint_deploy
        else
            echo "There was a problem installing the streamer. Please try again."
            streamer_install
        fi
    fi
    
    if [ $VID -eq 3 ]; then
        echo "Good for you! Cameras are just annoying anyway."
    fi
}

initialize_nanofactory() {
    echo "Initializing NanoFactory" | log
    check_nanofactory_folder
    generate_nanofactory_apikey "/home/$user/.octoprint/data" "$OCTOADMIN"
    master_device_id_input "/home/$user/.octoprint/data"
}

check_nanofactory_folder(){
    if [ ! -d "/home/$user/.octoprint/data/NanoFactory" ]; then
        echo "Creating NanoFactory folder" | log
        sudo -u $user mkdir /home/$user/.octoprint/data/NanoFactory
        sudo chmod -R a+rwx /home/$user/.octoprint/data/NanoFactory
    fi
}

generate_nanofactory_apikey(){
    echo "Generating NanoFactory API Key" | log

    data_dir_path="$1"
    username="$2"

    # Generate the key 
    key=$(openssl rand -hex 16 | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z0-9' | head -c 32)

    # Update the key in the yaml file
    yq eval '.'"$username"'[0].api_key = "'"$key"'"' "$data_dir_path"/appkeys/keys.yaml -i
    yq eval '.'"$username"'[0].app_id = "NanoFactory"' "$data_dir_path"/appkeys/keys.yaml -i

    # Putting the key into the apiKey.txt file 
    echo "$key" > "$data_dir_path"/NanoFactory/apiKey.txt
}


master_device_id_input(){
    while true; do
        echo 'Enter Master Device ID: '
        read MASTER_DEVICE_ID
        if [ -z "$MASTER_DEVICE_ID" ]; then
            echo -e "No Master Device ID given!"
            MASTER_DEVICE_ID=""
        fi
        if ! has-space "$MASTER_DEVICE_ID"; then
            break
        else
            echo "Master Device ID must not have spaces."
        fi
        done

    echo "Master Device ID: $MASTER_DEVICE_ID" | log

    data_dir_path="$1"

    # Write the master device id to masterDeviceID.txt
    echo "$MASTER_DEVICE_ID" > "$data_dir_path"/NanoFactory/masterDeviceID.txt
}

install_yq() {
  echo "Installing yq..." | log

  # Determine the system type and select the appropriate binary
  case "$(uname -m)" in
    x86_64)
      binary_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
      binary_name="yq"
      ;;
    armv7l)
      binary_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm"
      binary_name="yq-arm"
      ;;
    *)
      echo "Unsupported system architecture for yq" | log
      return 0
      ;;
  esac


  # Download the latest `yq` binary release
  curl -sL "$binary_url" -o "$binary_name"

  # Make the binary executable
  chmod +x "$binary_name"

  # Move the binary to a directory in the system's `PATH`
  mv "$binary_name" /usr/local/bin/

  # Create a symbolic link with the same name as the `yq` command
  ln -sf "$(which $binary_name)" "$(dirname $(which $binary_name))/yq"
}

firstrun() {
    echo
    echo
    echo "Please setup your admin user now:";
        echo 'Enter admin user name (no spaces): '
        read OCTOADMIN
        if [ -z "$OCTOADMIN" ]; then
            echo -e "No admin user given! Defaulting to: \033[0;31mAdmin\033[0m"
            OCTOADMIN=Admin
        fi
        echo "Admin user: $OCTOADMIN"
        echo 'Enter admin user password (no spaces): '
        read OCTOPASS
        if [ -z "$OCTOPASS" ]; then
            echo -e "No password given! Defaulting to: \033[0;31mprinterverse\033[0m. Please CHANGE this."
            OCTOPASS=printerverse
        fi
        echo "Admin password: $OCTOPASS"
        $OCTOEXEC user add $OCTOADMIN --password $OCTOPASS --admin
    echo
    echo
    echo "Completing first run wizards" | log
    echo
    echo
    $OCTOEXEC config set server.firstRun false --bool | log
    $OCTOEXEC config set server.seenWizards.backup null | log
    $OCTOEXEC config set server.seenWizards.corewizard 4 --int | log
    $OCTOEXEC config set server.onlineCheck.enabled true --bool | log
    $OCTOEXEC config set server.pluginBlacklist.enabled true --bool | log
    $OCTOEXEC config set plugins.tracking.enabled false --bool | log
    $OCTOEXEC config set printerProfiles.default _default | log

    generate_nanofactory_apikey "/home/$user/.octoprint/data" "$OCTOADMIN" 
}

detect_camera() {
    dmesg -C
    echo "Plug your camera in via USB now (detection time-out in 1 min)"
    counter=0
    while [[ -z "$CAM" ]] && [[ $counter -lt 60 ]]; do
        CAM=$(dmesg | sed -n -e 's/^.*SerialNumber: //p')
        TEMPUSBCAM=$(dmesg | sed -n -e 's|^.*input:.*/\(.*\)/input/input.*|\1|p')
        counter=$(( $counter + 1 ))
        if [[ -n "$TEMPUSBCAM" ]] && [[ -z "$CAM" ]]; then
            break
        fi
        sleep 1
    done
    dmesg -C
}

write_camera() {
    
    get_settings
    if [ -z "$STREAMER" ]; then
        STREAMER="mjpg-streamer"
    fi
    
    #mjpg-streamer
    if [ "$STREAMER" == mjpg-streamer ]; then
        cat $SCRIPTDIR/octocam_mjpg.service | \
        sed -e "s/OCTOUSER/$OCTOUSER/" \
        -e "s/OCTOCAM/cam${INUM}_$INSTANCE/" \
        -e "s/RESOLUTION/$RESOLUTION/" \
        -e "s/FRAMERATE/$FRAMERATE/" \
        -e "s/CAMPORT/$CAMPORT/" > $SCRIPTDIR/cam${INUM}_$INSTANCE.service
    fi
    
    #ustreamer
    if [ "$STREAMER" == ustreamer ]; then
        cat $SCRIPTDIR/octocam_ustream.service | \
        sed -e "s/OCTOUSER/$OCTOUSER/" \
        -e "s/OCTOCAM/cam${INUM}_$INSTANCE/" \
        -e "s/RESOLUTION/$RESOLUTION/" \
        -e "s/FRAMERATE/$FRAMERATE/" \
        -e "s/CAMPORT/$CAMPORT/" > $SCRIPTDIR/cam${INUM}_$INSTANCE.service
    fi
    
    mv $SCRIPTDIR/cam${INUM}_$INSTANCE.service /etc/systemd/system/
    echo $CAMPORT >> /etc/camera_ports
    #config.yaml modifications - only if INUM not set
    if [ -z "$INUM" ]; then
        sudo -u $user $OCTOEXEC --basedir $OCTOCONFIG/.$INSTANCE config set plugins.classicwebcam.snapshot "http://localhost:$CAMPORT?action=snapshot"
        
        if [ -z "$CAMHAPROXY" ]; then
            sudo -u $user $OCTOEXEC --basedir $OCTOCONFIG/.$INSTANCE config set plugins.classicwebcam.stream "http://$(hostname).local:$CAMPORT?action=stream"    
        else
            sudo -u $user $OCTOEXEC --basedir $OCTOCONFIG/.$INSTANCE config set plugins.classicwebcam.stream "/cam_$INSTANCE/?action=stream"
        fi
        sudo -u $user $OCTOEXEC --basedir $OCTOCONFIG/.$INSTANCE config append_value --json system.actions "{\"action\": \"Reset video streamer\", \"command\": \"sudo systemctl restart cam_$INSTANCE\", \"name\": \"Restart webcam\"}"
    
        if prompt_confirm "Instance must be restarted for settings to take effect. Restart now?"; then
            systemctl restart $INSTANCE
        fi
    fi
    
    #Either Serial number or USB port
    #Serial Number
    if [ -n "$CAM" ]; then
        echo SUBSYSTEM==\"video4linux\", ATTRS{serial}==\"$CAM\", ATTR{index}==\"0\", SYMLINK+=\"cam${INUM}_$INSTANCE\" >> /etc/udev/rules.d/99-octoprint.rules
    fi
    
    #USB port camera
    if [ -n "$USBCAM" ]; then
        echo SUBSYSTEM==\"video4linux\",KERNELS==\"$USBCAM\", SUBSYSTEMS==\"usb\", ATTR{index}==\"0\", DRIVERS==\"uvcvideo\", SYMLINK+=\"cam${INUM}_$INSTANCE\" >> /etc/udev/rules.d/99-octoprint.rules
    fi
    
    if [ -n "$CAMHAPROXY" ]; then
        HAversion=$(haproxy -v | sed -n 's/^.*version \([0-9]\).*/\1/p')
        #find frontend line, do insert
        sed -i "/option forwardfor except 127.0.0.1/a\        use_backend cam${INUM}_$INSTANCE if { path_beg /cam${INUM}_$INSTANCE/ }" /etc/haproxy/haproxy.cfg
        #sed -i "/use_backend $INSTANCE if/a\        use_backend cam${INUM}_$INSTANCE if { path_beg /cam${INUM}_$INSTANCE/ }" /etc/haproxy/haproxy.cfg
        if [ $HAversion -gt 1 ]; then
            EXTRACAM="backend cam${INUM}_$INSTANCE\n\
            http-request replace-path /cam${INUM}_$INSTANCE/(.*)   /|\1\n\
            server webcam1 127.0.0.1:$CAMPORT"
        else
            EXTRACAM="backend cam${INUM}_$INSTANCE\n\
            reqrep ^([^|\ :]*)|\ /cam${INUM}_$INSTANCE/(.*) |\1|\ /|\2 \n\
            server webcam1 127.0.0.1:$CAMPORT"
        fi
        
        echo "#cam${INUM}_$INSTANCE start" >> /etc/haproxy/haproxy.cfg
        sed -i "/#cam${INUM}_$INSTANCE start/a $EXTRACAM" /etc/haproxy/haproxy.cfg
        #these are necessary because sed append seems to have issues with escaping for the /\1
        sed -i 's/\/|1/\/\\1/' /etc/haproxy/haproxy.cfg
        sed -i 's/\/|2/\/\\2/' /etc/haproxy/haproxy.cfg
        #haproxy 1.x correction
        sed -i 's/|/\\/g' /etc/haproxy/haproxy.cfg
        echo "#cam${INUM}_$INSTANCE stop" >> /etc/haproxy/haproxy.cfg
        
        systemctl restart haproxy
    fi
}

add_camera() {
    PI=$1
    INUM=''
    get_settings
    if [ $SUDO_USER ]; then user=$SUDO_USER; fi
    INSTANCE=octoprint
    OCTOCONFIG="/home/$user/"
    OCTOUSER=$user
    if [ -f "/etc/udev/rules.d/99-octoprint.rules" ]; then
        if grep -q "cam_$INSTANCE" /etc/udev/rules.d/99-octoprint.rules; then
            echo "It appears this instance already has at least one camera."
            if prompt_confirm "Do you want to add an additional camera for this instance?"; then
                echo "Enter a number for this camera."
                echo "Ex. entering 2 will setup a service called cam2_$INSTANCE"
                echo
                read INUM
                if [ -z "$INUM" ]; then
                    echo "No value given, setting as 2"
                    INUM='2'
                fi
            else
                main_menu
            fi
        fi
    fi
    
    #for now just set a flag that we are going to write cameras behind haproxy
    if [ "$HAPROXY" == true ]; then
        if prompt_confirm "Add cameras to haproxy?"; then
            CAMHAPROXY=1
        fi
    fi
    
    if [ -z "$PI" ]; then
        detect_camera
        if [ -n "$NOSERIAL" ] && [ -n "$CAM" ]; then
            unset CAM
        fi
        #Failed state. Nothing detected
        if [ -z "$CAM" ] && [ -z "$TEMPUSBCAM" ] ; then
            echo
            echo -e "\033[0;31mNo camera was detected during the detection period.\033[0m"
            echo
            return
        fi
        
        if [ -z "$CAM" ]; then
            echo "Camera Serial Number not detected"
            echo -e "Camera will be setup with physical USB address of \033[0;32m $TEMPUSBCAM.\033[0m"
            echo "The camera will have to stay plugged into this location."
            USBCAM=$TEMPUSBCAM
        else
            echo -e "Camera detected with serial number: \033[0;32m $CAM \033[0m"
        fi
        
    else
        echo
        echo
        echo "Setting up a Pi camera service for /dev/video0"
        echo "Please note that mixing this setup with USB cameras may lead to issues."
        echo "Don't expect extensive support for trying to fix these issues."
        echo
        echo
    fi
    
    while true; do
        echo "Camera Port (ENTER will increment last value in /etc/camera_ports):"
        read CAMPORT
        if [ -z "$CAMPORT" ]; then
            CAMPORT=$(tail -1 /etc/camera_ports)
        fi
        
        if [ -z "$CAMPORT" ]; then
            CAMPORT=8000
        fi
        
        CAMPORT=$((CAMPORT+1))
        
        if [ $CAMPORT -gt 7000 ]; then
            break
        else
            echo "Camera Port must be greater than 7000"
        fi
        
        
    done
    
    echo "Settings can be modified after initial setup in /etc/systemd/system/cam${INUM}_$INSTANCE.service"
    echo
    while true; do
        echo "Camera Resolution [default: 640x480]:"
        read RESOLUTION
        if [ -z $RESOLUTION ]
        then
            RESOLUTION="640x480"
            break
        elif [[ $RESOLUTION =~ ^[0-9]+x[0-9]+$ ]]
        then
            break
        fi
        echo "Invalid resolution"
    done
    echo "Selected camera resolution: $RESOLUTION"
    echo "Camera Framerate (use 0 for ustreamer hardware) [default: 5]:"
    read FRAMERATE
    if [ -z "$FRAMERATE" ]; then
        FRAMERATE=5
    fi
    echo "Selected camera framerate: $FRAMERATE"
    
    write_camera
    #Pi Cam setup, replace cam_INSTANCE with /dev/video0
    if [ -n "$PI" ]; then
        echo SUBSYSTEM==\"video4linux\", ATTRS{name}==\"camera0\", SYMLINK+=\"cam${INUM}_$INSTANCE\" >> /etc/udev/rules.d/99-octoprint.rules
    fi
    systemctl start cam${INUM}_$INSTANCE.service
    systemctl enable cam${INUM}_$INSTANCE.service
    systemctl daemon-reload
    udevadm control --reload-rules
    udevadm trigger
    main_menu
    
}


remove_everything() {
    get_settings
    if [ -f "/etc/octoprint_deploy" ]; then
        rm -f /etc/octoprint_deploy
    fi
    if [ -d "/home/$user/mjpg-streamer" ]; then
        rm -rf /home/$user/mjpg-streamer
    fi
    if [ -d "/home/$user/ustreamer" ]; then
        rm -rf /home/$user/ustreamer
    fi
    if [ -d "/home/$user/.octoprint" ]; then
        rm -rf /home/$user/.octoprint
    fi
    if [ -f "/etc/systemd/system/octoprint.service" ]; then
        systemctl stop octoprint
        systemctl disable octoprint
        rm -f /etc/systemd/system/octoprint.service
    fi
    if [ -f "/etc/systemd/system/cam_octoprint.service" ]; then
        systemctl stop cam*_octoprint
        systemctl disable cam*_octoprint
        rm -f /etc/systemd/system/cam*_octoprint.service
    fi
    if [ -d "/home/$user/OctoPrint" ]; then
        rm -rf /home/$user/OctoPrint
    fi
    if [ -f "/etc/udev/rules.d/99-octoprint.rules" ]; then
        rm -f /etc/udev/rules.d/99-octoprint.rules
    fi
    if [ -f "/etc/camera_ports" ]; then
        rm -f /etc/camera_ports
    fi
    rm -rf /home/$user/NanoFactory
}

main_menu() {
    VERSION=0.2.0
    CAM=''
    TEMPUSBCAM=''
    echo
    echo
    echo "*************************"
    echo "octoprint_install $VERSION"
    echo "*************************"
    echo
    PS3='Select operation: '
    if [ -f "/etc/octoprint_deploy" ]; then
        options=("Add USB Camera" "Quit")
    else
        options=("Install OctoPrint" "Quit")
    fi
    
    select opt in "${options[@]}"; do
        case $opt in
            "Install OctoPrint")
                prepare
                break
            ;;
            "Add USB Camera")
                add_camera
                break
            ;;
            "Quit")
                exit 1
            ;;
            *) echo "invalid option $REPLY" ;;
        esac
    done
}

#command line arguments
if [ "$1" == remove ]; then
    if prompt_confirm "Yeet everything?"; then
        remove_everything
    fi
fi

if [ "$1" == picam ]; then
    add_camera true
fi

main_menu
