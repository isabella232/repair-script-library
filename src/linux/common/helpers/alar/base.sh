#!/bin/bash

# Variables
#export UBUNTU_DISTRO="true"
export isRedHat="false"
export isRedHat6="false"
export isSuse="false"
export isUbuntu="false"
export isUbuntuEFI="false"
export tmp_dir=""
export recover_action=""
export boot_part=""
export rescue_root=""
export isExt4="false"
export isExt3="false"
export isXFS="false"
export isLVM="false"
export efi_part=""
export osNotSupported="true" # set to true by default, gets changed to false if this is the case
export tmp_dir=""
export global_error="false"
export actions="fstab initrd kernel" # These are the basic actions at the moment
export root_part_fs # set in distro-test
export LVM_SUPPRESS_FD_WARNINGS=1 

# Functions START
# Define some helper functions

. ./src/linux/common/setup/init.sh

recover_action() {
    cd "${tmp_dir}"
    local recover_action=$1

    if [[ -f "${tmp_dir}/alar-fki/${recover_action}.sh" ]]; then
        Log-Info "Starting recover action:  ${recover_action}"
        chmod 700 "${tmp_dir}/alar-fki/${recover_action}.sh"
        chroot /mnt/rescue-root "${tmp_dir}/alar-fki/${recover_action}.sh"
        Log-Info "Recover action:  ${recover_action} finished"
    else
        Log-Error "File ${recover_action}.sh does not exist. Exiting ALAR"
        global_error="true"
    fi

    [[ ${global_error} == "true" ]] && return 11
}


isInAction() {
    #be quiet, just let us know this action exists
    grep -q "$1" <<<"$actions"
    return "$?"
}

copyRecoverScriptsToTemp() {
        cp -Lr ./src/linux/common/helpers/alar/* ${tmp_dir} 
        cp -Lr ./src/linux/common/* ${tmp_dir}
        mkdir -p ${tmp_dir}/src/linux/common
        ln -s ${tmp_dir}/helpers ${tmp_dir}/src/linux/common/helpers
        ln -s ${tmp_dir}/setup ${tmp_dir}/src/linux/common/setup
}

# Funtions END

#
# Start of the script
#

# Create tmp dir in order to store our files we download
tmp_dir="$(mktemp -d)"
copyRecoverScriptsToTemp
cd "${tmp_dir}"

# Filename for the distro verification
distro_test="distro-test.sh"

# Global redirection for ERR to STD
exec 2>&1

#
# What OS we need to recover?
#
if [[ -f "$tmp_dir/alar-fki/${distro_test}" ]]; then
    chmod 700 "${tmp_dir}/alar-fki/${distro_test}"
    . "${tmp_dir}/alar-fki/${distro_test}" # invoke the distro test

    # Do we have identifed a supported distro?
    if [[ ${osNotSupported} == "true" ]]; then
        Log-Error " Your OS can not be determined. The OS distros supported are"
        Log-Error " CentOS/Redhat 6.8 - 8.2"
        Log-Error " Ubuntu 16.4 LTS and Ubuntu 18.4 LTS"
        Log-Error " Suse 12 and 15"
        Log-Error " Debain 9 and 10"
        Log-Error " ALAR will stop!"
        Log-Error " If your OS is in the above list please report this issue at https://github.com/azure/repair-script-library/issues"
        exit 1
    fi
else
    Log-Error "File ${distro_test}.sh could not be fetched. Exiting"
    exit 1
fi

# Prepare and mount the partitions. Take into account what distro we have to deal with
# At first we have to mount the root partion of the VM we need to recover

if [[ ! -d /mnt/rescue-root ]]; then
    mkdir /mnt/rescue-root
fi

# At the moment we handle only LVM on RedHat/CentOS
if [[ ${isLVM} == "true" ]]; then
    pvscan
    vgscan
    lvscan
    rootlv=$(lvscan | grep rootlv | awk '{print $2}' | tr -d "'")
    tmplv=$(lvscan | grep tmplv | awk '{print $2}' | tr -d "'")
    optlv=$(lvscan | grep optlv | awk '{print $2}' | tr -d "'")
    usrlv=$(lvscan | grep usrlv | awk '{print $2}' | tr -d "'")
    varlv=$(lvscan | grep varlv | awk '{print $2}' | tr -d "'")

    # The mount tool is automatically able to handle other fs-types 
    mount ${rootlv} /mnt/rescue-root
    #mount ${tmplv} /mnt/rescue-root/tmp
    #mount ${optlv} /mnt/rescue-root/opt
    mount ${usrlv} /mnt/rescue-root/usr
    mount ${varlv} /mnt/rescue-root/var
# No LVM, thus do the normal mount steps
elif [[ "${isRedHat}" == "true" || "${isSuse}" == "true" ]]; then
    # noouid is valid for XFS only
    # The extra step is only performed to be sure we have no overlaps with any UUID on an XFS FS
    if [[ "${isExt4}" == "true" ]]; then
        mount -n "${rescue_root}" /mnt/rescue-root
    elif [[ "${isXFS}" == "true" ]]; then
        mount -n -o nouuid "${rescue_root}" /mnt/rescue-root
    fi
fi


if [[ "$isUbuntu" == "true" ]]; then
    mount -n "$rescue_root" /mnt/rescue-root
fi

#Mount the boot part
#===================

# Ubuntu does not have an extra boot partition
if [[ "$isRedHat" == "true" || "$isSuse" == "true" ]]; then
    # noouid is valid for XFS only
    if [[ "${isExt4}" == "true" || "${isExt3}" == "true" ]]; then
        mount "${boot_part}" /mnt/rescue-root/boot
    elif [[ "${isXFS}" == "true" ]]; then
        mount -o nouuid "${boot_part}" /mnt/rescue-root/boot
    fi
fi

# EFI partitions are only able to be mounted after we have mounted the boot partition
if [[ -n "$efi_part" ]]; then 
    mount "${efi_part}" /mnt/rescue-root/boot/efi
fi



#Mount the support filesystems
#==============================
#see also http://linuxonazure.azurewebsites.net/linux-recovery-using-chroot-steps-to-recover-vms-that-are-not-accessible/
for i in dev proc sys tmp dev/pts; do
    if [[ ! -d /mnt/rescue-root/"$i" ]]; then
        mkdir /mnt/rescue-root/"$i"
    fi
    mount -o bind /"$i" /mnt/rescue-root/"$i"
done

if [[ "${isUbuntu}" == "true" || "${isSuse}" == "true" ]]; then
    if [[ ! -d /mnt/rescue-root/run ]]; then
        mkdir /mnt/rescue-root/run
    fi
    mount -o bind /run /mnt/rescue-root/run
fi

# Reformat the action value
action_value=$(echo $1 | tr ',' ' ')
recover_status=""
# What action has to be performed now?
for k in $action_value; do
    if [[ $(isInAction $k) -eq 0 ]]; then
        case "${k,,}" in
        fstab)
            Log-Info "We have fstab as option"
            recover_action "$k"
            recover_status=0
            ;;
        kernel)
            Log-Info "We have kernel as option"
            recover_action "$k"
            recover_status=0
            ;;
        initrd)
            Log-Info "We have initrd as option"
            recover_action "$k"
            recover_status=0
            ;;
        esac
    fi
done

#Clean up everything
cd /
for i in dev/pts proc tmp sys dev; do umount /mnt/rescue-root/"$i"; done

if [[ "$isUbuntu" == "true" || "$isSuse" == "true" ]]; then
    #is this really needed for Suse?
    umount /mnt/rescue-root/run
fi

if [[ "${isLVM}" == "true" ]]; then
   # umount /mnt/rescue-root/tmp
   # umount /mnt/rescue-root/opt
    umount /mnt/rescue-root/usr
    umount /mnt/rescue-root/var
fi

if [[ -n "$efi_part" ]]; then 
    umount "${efi_part}" 
fi

umount /mnt/rescue-root/boot
umount /mnt/rescue-root
rmdir /mnt/rescue-root
rm -fr "${tmp_dir}"

if [[ "${recover_status}" == "11" ]]; then
    Log-Error "The recover action throwed an error"
    exit $STATUS_ERROR
else
    exit $STATUS_SUCCESS
fi