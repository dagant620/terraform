##DATASOURCES

# Gets a list of Availability Domains
data "oci_identity_availability_domains" "ADs" {
  compartment_id = "${var.tenancy_ocid}"
}

#Get a list of avaialble shapes
data "oci_core_shapes" "test_shapes" {
    #Required
    compartment_id = "${var.compartment_ocid}"
}

##INSTANCE CREATION

resource "oci_core_instance" "TFInstance" {
  count               = "${var.NumInstances}"
   availability_domain = "${element(var.availability_domain, count.index)}"
#  availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.availability_domain - 1],"name")}"
#  fault_domain        = "${var.instance_fault_domain}"
  compartment_id      = "${var.compartment_ocid}"
  display_name = "${var.instance_display_name == "" ? "" : "${var.NumInstances != "1" ? "${var.instance_display_name}0${count.index + 1}" : "${var.instance_display_name}"}"}"
# display_name        = "${format("TFInstance0%d", count.index + 1)}"
  shape               = "${var.instance_shape}"

  create_vnic_details {
    subnet_id        = "${var.OCI_PROD_ZMD}"
    display_name     = "primaryvnic"
    assign_public_ip = false
    hostname_label = "${var.hostname_label == "" ? "" : "${var.NumInstances != "1" ? "${var.hostname_label}0${count.index + 1}" : "${var.hostname_label}"}"}"
  # hostname_label   = "${format("TFInstance0%d", count.index + 1)}"
  }

  source_details {
    source_type = "image"
    source_id   = "${var.instance_image_ocid[var.region]}"
  }

  # Apply the following flag only if you wish to preserve the attached boot volume upon destroying this instance
  # Setting this and destroying the instance will result in a boot volume that should be managed outside of this config.
  # When changing this value, make sure to run 'terraform apply' so that it takes effect before the resource is destroyed.
  #preserve_boot_volume = true

#  Copies the authorized_keys file to /home/user/.ssh
#    provisioner "file" {
#    source      = "/home/dagant/.ssh/authorized_keys"
#    destination = "/home/dagant/.ssh/authorized_keys"
    
#    connection {
#    type     = "ssh"
#    user     = "opc"
    #password = "${var.root_password}"
 # }
#}

   metadata {
    ssh_authorized_keys = "${var.ssh_public_key}"
#    user_data           = "${base64encode(file(var.BootStrapFile))}"
}
}
##BLOCK STORAGE CREATION
resource "oci_core_volume" "TFInstanceblock" {
  count               = "${var.NumInstances * var.NumIscsiVolumesPerInstance}"
  availability_domain = "${element(var.availability_domain, count.index)}"
# availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.availability_domain - 1],"name")}"
  compartment_id      = "${var.compartment_ocid}"
 # display_name        = "${oci_core_instance.TFInstance.*.display_name[count.index % var.NumInstances]}-disk0${count.index / var.NumInstances}" 
  display_name = "${oci_core_instance.TFInstance.*.display_name[count.index % var.NumInstances]}${format("-disk01")}"
  size_in_gbs         = "${var.DiskSize}"

#source_details {
        #Required
#        id = "${var.volume_source_details_id}"
#        type = "volume"
#   }
}

##INSTANCE STORAGE ATTACHMENT
resource "oci_core_volume_attachment" "TFInstanceblock-attach" {
  count           = "${var.NumInstances * var.NumIscsiVolumesPerInstance}"
  attachment_type = "iscsi"
  compartment_id  = "${var.compartment_ocid}"
  instance_id     = "${oci_core_instance.TFInstance.*.id[count.index / var.NumIscsiVolumesPerInstance]}"
  volume_id       = "${oci_core_volume.TFInstanceblock.*.id[count.index]}"

  # Set this to enable CHAP authentication for an ISCSI volume attachment. The oci_core_volume_attachment resource will
  # contain the CHAP authentication details via the "chap_secret" and "chap_username" attributes.
  #use_chap = true

  # Set this to attach the volume as read-only.
  #is_read_only = true
}

resource "oci_core_volume" "TFInstance_pv" {
  count               = "${var.NumInstances * var.NumParavirtualizedVolumesPerInstance}"
  availability_domain = "${lookup(data.oci_identity_availability_domains.ADs.availability_domains[var.availability_domain - 1],"name")}"
  compartment_id      = "${var.compartment_ocid}"
  display_name        = "TFInstance_pv${count.index}"
# size_in_gbs         = "${var.DBSize}"

source_details {
        #Required
        id = "ocid1.volume.oc1.iad.abuwcljt46lbforxea2qo33ilvjfe534sr7yvawlzby3ligoo4p2l7ehktcq"
        type = "volume"
    }
}

resource "oci_core_volume_attachment" "TFBlockAttachParavirtualized" {
  count           = "${var.NumInstances * var.NumParavirtualizedVolumesPerInstance}"
  attachment_type = "paravirtualized"
  compartment_id  = "${var.compartment_ocid}"
  instance_id     = "${oci_core_instance.TFInstance.*.id[count.index / var.NumParavirtualizedVolumesPerInstance]}"
  volume_id       = "${oci_core_volume.TFInstance_pv.*.id[count.index]}"


  # Set this to attach the volume as read-only.
  #is_read_only = true
}

##REMOTE EXEC
resource "null_resource" "remote-exec" {
  depends_on = ["oci_core_instance.TFInstance", "oci_core_volume_attachment.TFInstanceblock-attach"]
  count      = "${var.NumInstances * var.NumIscsiVolumesPerInstance}"

  provisioner "remote-exec" {
    connection {
      agent       = false
      timeout     = "5m"
      host        = "${oci_core_instance.TFInstance.*.private_ip[count.index % var.NumInstances]}"
      user        = "opc"
      private_key = "${var.ssh_private_key}"
}

    inline = [
      "touch ~/IMadeAFile.Right.Here",
      "sudo iscsiadm -m node -o new -T ${oci_core_volume_attachment.TFInstanceblock-attach.*.iqn[count.index]} -p ${oci_core_volume_attachment.TFInstanceblock-attach.*.ipv4[count.index]}:${oci_core_volume_attachment.TFInstanceblock-attach.*.port[count.index]}",
      "sudo iscsiadm -m node -o update -T ${oci_core_volume_attachment.TFInstanceblock-attach.*.iqn[count.index]} -n node.startup -v automatic",
      "echo sudo iscsiadm -m node -T ${oci_core_volume_attachment.TFInstanceblock-attach.*.iqn[count.index]} -p ${oci_core_volume_attachment.TFInstanceblock-attach.*.ipv4[count.index]}:${oci_core_volume_attachment.TFInstanceblock-attach.*.port[count.index]} -l >> ~/.bashrc",
"sudo sed -i '18i/dev/mapper/vg01-manh   /manh     xfs       defaults,noatime,_netdev    0 0' /etc/fstab",
"sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config"

    ]
  }
}

#Output the Display ane of the Instance
output "InstanceDisplayName" {
  value = ["${oci_core_instance.TFInstance.*.display_name}"]
}

# Output the private and public IPs of the instance
output "InstancePrivateIPs" {
  value = ["${oci_core_instance.TFInstance.*.private_ip}"]
}

# Output the boot volume IDs of the instance
output "BootVolumeIDs" {
  value = ["${oci_core_instance.TFInstance.*.boot_volume_id}"]
}


