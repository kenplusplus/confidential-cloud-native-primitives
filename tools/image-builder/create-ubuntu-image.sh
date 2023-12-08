#!/bin/bash
#
# Create a Ubuntu EFI cloud TDX guest image. It can run on any Linux system with
# required tool installed like qemu-img, virt-customize, virt-install, etc. It is
# not required to run on a TDX capable system.
#

CURR_DIR=$(dirname "$(realpath $0)")
FORCE_RECREATE=false
IMAGE_DAILY="current"
OFFICIAL_UBUNTU_IMAGE="https://cloud-images.ubuntu.com/jammy/${IMAGE_DAILY}/"
CLOUD_IMG="jammy-server-cloudimg-amd64.img"
GUEST_IMG="tdx-guest-ubuntu-22.04.qcow2"
SIZE="20G"
GUEST_USER="tdx"
GUEST_PASSWORD="123456"
GUEST_HOSTNAME="tdx-guest"
KERNEL_VERSION=""
GUEST_REPO=""
AUTH_FILE=""
VIR_SCRIPT_PRE=""
VIR_SCRIPT_PST=""
CUS_CLOUD_CONFIG=""
CUS_SCRIPT=""
DEBUG_MODE=false
TEST_SUITE=false
CONFIG_PATH=$CURR_DIR/config/default.yaml

INITRD_SRC_ARR=""
INITRD_DST_ARR=""

ok() {
    echo -e "\e[1;32mSUCCESS: $*\e[0;0m"
}

error() {
    echo -e "\e[1;31mERROR: $*\e[0;0m"
    cleanup
    exit 1
}

warn() {
    echo -e "\e[1;33mWARN: $*\e[0;0m"
}

check_tool() {
    [[ "$(command -v $1)" ]] || { error "$1 is not installed" 1>&2 ; }
}

usage() {
    cat <<EOM
Usage: $(basename "$0") [OPTION]...
Required
  -r <guest repo>           Specify the directory including guest packages, generated by build-repo.sh or remote repo
Test suite
  -t                        Install test suite
Optional
  -v <kernel version>       Specify the version of the guest kernel, like 6.2.16-mvp30v3+7-generic of
                            linux-image-unsigned-6.2.16-mvp30v3+7-generic. If the guest repo is remote,
                            the option is necessary. 
  -a                        Auth file that will be placed in /etc/apt/auth.conf.d
  -h                        Show this help
  -f                        Force to recreate the output image
  -n                        Guest host name, default is "tdx-guest"
  -u                        Guest user name, default is "tdx"
  -p                        Guest password, default is "123456"
  -s                        Specify the size of guest image, Optional suffixes
                            'k' or 'K' (kilobyte, 1024), 'M' (megabyte, 1024k), 'G' (gigabyte, 1024M),
                            'T' (terabyte, 1024G), 'P' (petabyte, 1024T) and 'E' (exabyte, 1024P)  are
                            supported. 'b' is ignored.
  -o <output file>          Specify the output file, default is tdx-guest-ubuntu-22.04.qcow2.
                            Please make sure the suffix is qcow2. Due to permission consideration,
                            the output file will be put into /tmp/<output file>.
  -b                        Debug Mode
                            - enable root login
  -c <path-to-config-file>  The path to the config file, default config file is placed in config/default.yaml
                            Note: config file provides advanced config options, but the command line option will
                            OWERWRITE the same option in the config file. 
Customization
  -i                        Customized script run by virt-customize before invoking cloud-init (the script is interpreted by /bin/sh)
  -d                        Customized script run by virt-customize after invoking cloud-init (the script is interpreted by /bin/sh)
  -g                        Customized cloud-config appended to the user-data
  -x                        Customized script appended to the user-data (running after all runcmd in cloud-config)
EOM
}

process_args() {
    while getopts "o:s:n:u:p:r:a:v:i:d:g:x:c:fhtb" option; do
        case "$option" in
        o) GUEST_IMG=$OPTARG ;;
        s) SIZE=$OPTARG ;;
        n) GUEST_HOSTNAME=$OPTARG ;;
        u) GUEST_USER=$OPTARG ;;
        p) GUEST_PASSWORD=$OPTARG ;;
        r) GUEST_REPO=$OPTARG ;;
        a) AUTH_FILE=$OPTARG ;;
        v) KERNEL_VERSION=$OPTARG ;;
        i) VIR_SCRIPT_PRE=$OPTARG ;;
        d) VIR_SCRIPT_PST=$OPTARG ;;
        g) CUS_CLOUD_CONFIG=$OPTARG ;;
        x) CUS_SCRIPT=$OPTARG ;;
        f) FORCE_RECREATE=true ;;
        t) TEST_SUITE=true ;;
        b) DEBUG_MODE=true ;;
        c) CONFIG_PATH=$OPTARG ;;
        h)
            usage
            exit 0
            ;;
        *)
            echo "Invalid option '-$OPTARG'"
            usage
            exit 1
            ;;
        esac
    done

    echo $CONFIG_PATH
    # TODO: config file check
    . ./scripts/config-file-parser.sh
    INITRD_DST_ARR=$(parse_initrd_dst_paths $CONFIG_PATH)
    INITRD_DST_ARR=($INITRD_DST_ARR)
    INITRD_SRC_ARR=$(parse_initrd_src_paths $CONFIG_PATH)
    INITRD_SRC_ARR=($INITRD_SRC_ARR)
    len_of_arr=${#INITRD_SRC_ARR[@]}
    for ((i=0;i<len_of_arr;i++))
    do
        if [[ ${INITRD_SRC_ARR[i]} != "None" ]]; then
            if [[ ${INITRD_SRC_ARR[i]} == 'http:'* ]] || [[ ${INITRD_SRC_ARR[i]} == 'https:'* ]] ;then 
                mkdir -p ./download
                if [[ -z ./download/$(basename ${INITRD_SRC_ARR[i]}) ]]; then
                    wget -P ./download ${INITRD_SRC_ARR[i]}
                fi
                INITRD_SRC_ARR[i]=./download/$(basename ${INITRD_SRC_ARR[i]})
                
            fi
        fi
    done
    . ./pre-scripts/prepare-initrd.sh
    create_initramfs_tools_hooks  INITRD_SRC_ARR INITRD_DST_ARR

    echo "================================="
    echo "Guest image /tmp/${GUEST_IMG}"
    echo "Built from ${OFFICIAL_UBUNTU_IMAGE}${CLOUD_IMG}"
    echo "Guest package installed from ${GUEST_REPO}"
    echo "Test suite:       ${TEST_SUITE}" 
    echo "Debug mode:       ${DEBUG_MODE}" 
    echo "Force recreate:   ${FORCE_RECREATE}"
    echo "Kernel version:   ${KERNEL_VERSION}"
    echo "Size:             ${SIZE}"
    echo "Hostname:         ${GUEST_HOSTNAME}"
    echo "User:             ${GUEST_USER}"
    echo "Password:         ******"
    echo "================================="

    if [[ "${GUEST_IMG}" == "${CLOUD_IMG}" ]]; then
        error "Please specify a different name for guest image via -o"
    fi

    if [[ ${GUEST_IMG} != *.qcow2 ]]; then
        error "The output file should be qcow2 format with the suffix .qcow2."
    fi

    if [[ -f "/tmp/${GUEST_IMG}" ]]; then
        if [[ ${FORCE_RECREATE} != "true" ]]; then
            error "Guest image /tmp/${GUEST_IMG} already exist, please specify -f if want force to recreate"
        fi
    fi

    if [[ ${GUEST_REPO} != 'http:'* ]] && [[ ${GUEST_REPO} != 'https:'* ]] && [[ ${GUEST_REPO} != 'ftp:'* ]];then 
        if [[ -z ${GUEST_REPO} ]]; then
            error "No guest repository provided, skip to install TDX packages..."
        else
            if [[ ! -d ${GUEST_REPO} ]]; then
                error "The guest repo directory ${GUEST_REPO} does not exists..."
            fi
        fi
    fi

    if [[ $SIZE != *'k' ]] && \
       [[ $SIZE != *'K' ]] && \
       [[ $SIZE != *'M' ]] && \
       [[ $SIZE != *'G' ]] && \
       [[ $SIZE != *'T' ]] && \
       [[ $SIZE != *'P' ]] && \
       [[ $SIZE != *'E' ]]; then
            error "The guest image size $SIZE is unsupported, use -h to corrent the format"
    fi
}

cleanup() {
    if [[ -f ${CURR_DIR}/"SHA256SUMS" ]]; then
        rm ${CURR_DIR}/"SHA256SUMS"
    fi
    ok "Cleanup!"
}

#==================== func create_pristine_image ====================

download_image() {
    # Get the checksum file first
    if [[ -f ${CURR_DIR}/"SHA256SUMS" ]]; then
        rm ${CURR_DIR}/"SHA256SUMS"
    fi

    wget "${OFFICIAL_UBUNTU_IMAGE}/SHA256SUMS"

    while :; do
        # Download the cloud image if not exists
        if [[ ! -f ${CLOUD_IMG} ]]; then
            wget -O ${CURR_DIR}/${CLOUD_IMG} ${OFFICIAL_UBUNTU_IMAGE}/${CLOUD_IMG}
        fi

        # calculate the checksum
        download_sum=$(sha256sum ${CURR_DIR}/${CLOUD_IMG} | awk '{print $1}')
        found=false
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"$CLOUD_IMG"* ]]; then
                if [[ "${line%% *}" != ${download_sum} ]]; then
                    echo "Invalid download file according to sha256sum, re-download"
                    rm ${CURR_DIR}/${CLOUD_IMG}
                else
                    ok "Verify the checksum for Ubuntu cloud image."
                    return
                fi
                found=true
            fi
        done <"SHA256SUMS"
        if [[ $found != "true" ]]; then
            echo "Invalid SHA256SUM file"
            exit 1
        fi
    done
}

create_guest_image() {
    download_image

    cp ${CURR_DIR}/${CLOUD_IMG} /tmp/${GUEST_IMG}
    ok "Copy the ${CLOUD_IMG} => /tmp/${GUEST_IMG}"
}

config_guest_env() {
    virt-customize -a /tmp/${GUEST_IMG} \
        --copy-in /etc/environment:/etc
    ok "Copy host's environment file to guest for http_proxy"
}

resize_guest_image() {
    qemu-img resize /tmp/${GUEST_IMG} ${SIZE}
    virt-customize -a /tmp/${GUEST_IMG} \
        --run-command 'growpart /dev/sda 1' \
        --run-command 'resize2fs /dev/sda1' 
    ok "Resize the guest image to ${SIZE}"
}

create_pristine_image () {
    create_guest_image
    config_guest_env
    resize_guest_image
}

#==================== func pre_cloud_init ====================

basic_image_prepare() {
    ARGS=""
    # guest repo
    if [[ ${GUEST_REPO} != 'http:'* ]] && [[ ${GUEST_REPO} != 'https:'* ]] && [[ ${GUEST_REPO} != 'ftp:'* ]];then
        ARGS=$ARGS' --copy-in '${GUEST_REPO}':/srv/ '
    fi

    # repo auth
    if [ ! -z ${AUTH_FILE} ]; then
        ARGS=$ARGS' --copy-in '${AUTH_FILE}':/etc/apt/auth.conf.d/ '
    fi
    

    # copy in
    if [ ! -z "$ARGS" ]; then
        virt-customize -a /tmp/${GUEST_IMG} $ARGS
    fi
}

test_suite_prepare() {
    if [[ $TEST_SUITE == "false" ]]; then
        return
    fi

    # test data set
    mkdir -p ./download
    if [[ ! -f ./download/dien_bf16_pretrained_opt_model.pb ]]; then
        wget -P ./download https://storage.googleapis.com/intel-optimized-tensorflow/models/v2_5_0/dien_bf16_pretrained_opt_model.pb 
    fi
    if [[ ! -f ./download/dien_fp32_static_rnn_graph.pb ]]; then
        wget -P ./download https://storage.googleapis.com/intel-optimized-tensorflow/models/v2_5_0/dien_fp32_static_rnn_graph.pb 
    fi
    
    mkdir -p ./download/dien
    if [[ ! -f ./download/data.tar.gz ]]; then
        wget -P ./download https://zenodo.org/record/3463683/files/data.tar.gz
        tar -C ./download/ -jxvf ./download/data.tar.gz
        mv ./download/data/* ./download/dien
    fi

    if [[ ! -f ./download/data1.tar.gz ]]; then
        wget -P ./download https://zenodo.org/record/3463683/files/data1.tar.gz
        tar -C ./download/ -jxvf ./download/data1.tar.gz
        mv ./download/data1/* ./download/dien
    fi

    if [[ ! -f ./download/data2.tar.gz ]]; then
        wget -P ./download https://zenodo.org/record/3463683/files/data2.tar.gz
        tar -C ./download/ -jxvf ./download/data2.tar.gz
        mv ./download/data2/* ./download/dien
    fi
    
    if [[ ! -d ./download/models ]]; then
        git clone https://github.com/IntelAI/models.git -b v2.5.0 ./download/models
    fi
    
    virt-customize -a /tmp/${GUEST_IMG} \
        --copy-in ./download/dien_bf16_pretrained_opt_model.pb:/root \
        --copy-in ./download/dien_fp32_static_rnn_graph.pb:/root \
        --copy-in ./download/dien:/root \
        --copy-in ./download/models:/root 
}

pre_cloud_init () {
    basic_image_prepare
    
    . ./pre-scripts/prepare-initrd.sh
    INITRAMFS_TOOLS_DIR=./cache/etc/initramfs-tools
    src_pkgs=(${INITRD_SRC_ARR[@]})
    dst_pkgs=(${INITRD_DST_ARR[@]})
    src_pkgs+=("$INITRAMFS_TOOLS_DIR")
    dst_pkgs+=("/etc")
    copy_initramfs_tools_deps_into_image /tmp/${GUEST_IMG} src_pkgs dst_pkgs
    
    # if [ ! -z $VIR_SCRIPT_PRE ]; then
    #     virt-customize -a /tmp/${GUEST_IMG} --run $VIR_SCRIPT_PRE
    # fi
    ok "pre_cloud_init finish"
}

#==================== func cloud_init ====================

create_user_data() {
    GUEST_REPO_NAME=""
    guest_repo_source=""
    if [[ ${GUEST_REPO} == 'http:'* ]] || [[ ${GUEST_REPO} == 'https:'* ]] || [[ ${GUEST_REPO} == 'ftp:'* ]]; then 
        GUEST_REPO_NAME=$(basename ${GUEST_REPO})
        guest_repo_source='deb [trusted=yes] '$GUEST_REPO'/ jammy/all/\ndeb [trusted=yes] '$GUEST_REPO'/ jammy/amd64/'
    else
        GUEST_REPO_NAME=$(basename $(realpath ${GUEST_REPO}))
        guest_repo_source='deb [trusted=yes] file:/srv/'$GUEST_REPO_NAME'/ jammy/all/\ndeb [trusted=yes] file:/srv/'$GUEST_REPO_NAME'/ jammy/amd64/'
        if [ -z $KERNEL_VERSION ]; then
            kernel=$(basename $(find $GUEST_REPO -name linux-image-unsigned* | head -1))
            KERNEL_VERSION=$(echo $kernel | awk -F'_' '{print $1}')
            KERNEL_VERSION=$(echo ${KERNEL_VERSION#linux-image-unsigned-})
        fi
        
    fi

    # basic cloud-config
    pkgs=" \"linux-image-unsigned-$KERNEL_VERSION\"  , \
           \"linux-modules-$KERNEL_VERSION\"         , \
           \"linux-modules-extra-$KERNEL_VERSION\"   , \
           \"linux-headers-$KERNEL_VERSION\"
         "
    yq "
    .user=\"$GUEST_USER\" |
    .password=\"$GUEST_PASSWORD\" | 
    .apt.sources.\"$GUEST_REPO_NAME.list\".source=\"$guest_repo_source\" |
    .packages += [ $pkgs ]
    " ${CURR_DIR}/cloud-init-data/user-data-basic/cloud-config-base-template.yaml \
    > ${CURR_DIR}/cloud-init-data/cloud-config-base.yaml

    ARGS=' -a ./cloud-init-data/cloud-config-base.yaml:cloud-config'

    # test suite cloud
    if [[ $TEST_SUITE == "true" ]]; then
        
        cp ${CURR_DIR}/cloud-init-data/user-data-customized/cloud-config-test-suite-template.yaml \
        ${CURR_DIR}/cloud-init-data/cloud-config-test-suite.yaml
        
        ARGS=$ARGS' -a ./cloud-init-data/cloud-config-test-suite.yaml:cloud-config'
        ARGS=$ARGS' -a ./cloud-init-data/init-scripts/test-suite-docker-related.sh:x-shellscript'
    fi
    
    if [ ! -z $CUS_CLOUD_CONFIG ]; then
        ARGS=$ARGS' -a '$CUS_CLOUD_CONFIG':cloud-config'
    fi

    if [ ! -z $CUS_SCRIPT ]; then
        ARGS=$ARGS' -a '$CUS_SCRIPT':x-shellscript'
    fi

    cloud-init devel make-mime $ARGS > ./cloud-init-data/user-data
}


invoke_cloud_init() {
    pushd ${CURR_DIR}/cloud-init-data
    [ -e /tmp/ciiso.iso ] && rm /tmp/ciiso.iso

    # configure the meta-dta
    cp meta-data.template meta-data

    cat <<EOT >> meta-data

local-hostname: $GUEST_HOSTNAME
EOT

    ok "Generate configuration for cloud-init..."
    genisoimage -output /tmp/ciiso.iso -volid cidata -joliet -rock user-data meta-data
    ok "Generate the cloud-init ISO image..."
    popd

    virt-install --memory 4096 --vcpus 4 --name tdx-config-cloud-init \
        --disk /tmp/${GUEST_IMG} \
        --disk /tmp/ciiso.iso,device=cdrom \
        --os-type Linux \
	--os-variant ubuntu21.10 \
        --virt-type kvm \
        --graphics none \
        --import 
    ok "Complete cloud-init..."
    sleep 1

    virsh undefine tdx-config-cloud-init || true
}

cloud_init () {
    create_user_data
    invoke_cloud_init
    ok "cloud_init finish"
}

#==================== func pst_cloud_init ====================

install_tdx_measure_tool() {
    virt-customize -a /tmp/${GUEST_IMG} \
        --run-command "python3 -m pip install pytdxattest"
    ok "Install the TDX measurement tool..."
}

pst_cloud_init () {
    if [[ $TEST_SUITE == "true" ]]; then
        install_tdx_measure_tool
    fi
    
    if [ ! -z $VIR_SCRIPT_PST ]; then
        virt-customize -a /tmp/${GUEST_IMG} --run $VIR_SCRIPT_PST
    fi

    if [[ $DEBUG_MODE == "true" ]]; then
        virt-customize -a /tmp/${GUEST_IMG} \
            --run-command "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config"
    fi
    ok "pst_cloud_init finish"
}

#==================== func runtime_init ====================


runtime_init () {
    # ../../../start-qemu.sh -i /tmp/${GUEST_IMG} -b grub -t legacy & 
    # GUEST_PARENT_PID=$!
    # sleep 15

    # yes yes | ssh-keygen -R [localhost]:10026

    # todo:
    
    # # close guest vm
    # GUEST_PID=$(pgrep -P $GUEST_PARENT_PID)
    # kill -9 $GUEST_PID
    ok "runtime_init finish"
}

#==================== process start ====================


check_tool qemu-img
check_tool virt-customize
check_tool virt-install
check_tool genisoimage
check_tool cloud-init
check_tool git
check_tool awk
check_tool yq

process_args "$@"

#
# Check user permission
#
if (( $EUID != 0 )); then
    warn "Current user is not root, please use root permission via \"sudo\" or make sure current user has correct "\
         "permission by configuring /etc/libvirt/qemu.conf"
    warn "Please refer https://libvirt.org/drvqemu.html#posix-users-groups"
    sleep 5
fi

# 1. 
create_pristine_image

# 2. 
pre_cloud_init

# 3. 
cloud_init

# # 4.
# pst_cloud_init

# # 5.
# runtime_init 

ok "Please get the output TDX guest image file at /tmp/${GUEST_IMG}"


#==================== process end ====================