#!/bin/bash
# xhosts4dockernet_keeper.sh [DockerNetworkName | INET:]
# ------------------------------------------------------------------
# Supported values of a net mask size are: 8, 16 and 24 [bits] only.
# The "default" net mask size - if unsupported value has been met - 
# is 24 bits. Any networks having unsupported net mask size will be 
# treated like those having 24 bits masks.
# ------------------------------------------------------------------
# docker-network to be inspected, if no input passed:
NetworkName="dcr_itl_25"

if [[ $1 ]] ; then
  NetworkName="$1"
fi

# Force enable xhost's ACL support
xhost -

# If special "INET:" DockerNetworkName is met, remove all 
# the records of "inet" family from the ACL and exit.
if [[ "${NetworkName}" = "INET:" ]] ; then
  xhostIPs=$(xhost | sed -n 's/INET://p')
  for xip in $xhostIPs ; do
    xhost -${xip}
  done
  exit $?
fi

# Obtain address and mask size of the given docker-network.
dn=$(docker network inspect -f '{{json .IPAM.Config}}' ${NetworkName} | sed 's/\[//' | sed 's/\]//' | jq '.Subnet' | sed 's/"//g')
netMaskSz=${dn#*/}
netAddr=${dn%/*}

# Set up the IP address filter using the address and the net mask size. 
case "${netMaskSz}" in
  8)
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1 }').
    ;;
  16)
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1,$2 }').
    ;;
  24)
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1,$2,$3 }').
    ;;
  *)
    # Unsupported net mask size has been met. Treat it as "default", i.e. equal to 24
    # (Not forget to display a Warning message.)
    echo "Warning!"
    echo "Unsupported net mask size: ${netMaskSz} bits"
    echo "Supported values are: 8, 16 and 24 bits only."
    echo "Will treat your xhost's ACL as if the mask size was 24 bits."
    echo "This could lead to some unexpected results!"
    recFltr=INET:$(echo ${netAddr} | awk 'BEGIN { FS = "."; OFS="." } ; { print $1,$2,$3 }').
    ;;
esac


# It's time to treat xhost's ACL:
# -------------------------------
# 1. Add to xhost's ACL all the found IPs of all running 
# containers - members of the given docker-network.
# xhost is smart enough to not add the already added IP.

dockerIPs=$(docker network inspect -f '{{json .Containers}}' ${NetworkName} | jq '.. | if type=="object" and has("Name") then .IPv4Address else empty end' | sed  's/"//g' | sed 's/\/[0-9]*//')

for ip in $dockerIPs ; do
  xhost +${ip}
done

# 2. Clear xhost ACL records that do not correspond to any running container
# of the given docker-network.
xhostIPs=$(xhost | grep ${recFltr} | sed 's/INET://')
for xip in $xhostIPs ; do
  if [[ -z "$(echo $dockerIPs | grep ${xip})" ]] ; then
    xhost -${xip}
  fi
done
