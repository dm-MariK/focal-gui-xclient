FROM ubuntu:20.04

# Define DISPLAY as ARG; set up DISPLAY for root user
ARG DISPLAY=10.255.25.1:0
ENV DISPLAY=${DISPLAY}

# Define non-root user, it's UID, gecos string and password
ARG user=bob
ARG uid=1000
ARG gecos="Saul Goodman"
ARG password=${user}

# Prepare "internal" Docker volume for /opt/matlab
VOLUME /opt/matlab

# Copy configs' tarball to /configs.tar.bz2
COPY configs.tar.bz2 /

# + Install most important packages
# + Install basic fonts
# + Install additional fonts
# + Install libraries -- dependences of MatLab
# + Unpack configs; remove configs' tarball
# + Set up root password
# + Add non-root user
RUN <<EOT bash
  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo bash-completion net-tools vim iputils-ping nmap htop mc ssh xauth xterm mesa-utils
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ttf-mscorefonts-installer ttf-dejavu ttf-xfree86-nonfree fonts-dejavu-core fonts-freefont-ttf fonts-opensymbol fonts-urw-base35 fonts-symbola ttf-bitstream-vera 
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ttf-unifont xfonts-unifont fonts-prociono ttf-ubuntu-font-family fonts-georgewilliams fonts-hack fonts-yanone-kaffeesatz ttf-aenigma ttf-anonymous-pro ttf-engadget ttf-sjfonts ttf-staypuft ttf-summersby 
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libgtk2.0-0 libnss3 libatk-bridge2.0-0 libgbm1 
  tar xf /configs.tar.bz2 --overwrite --directory=/ && rm -f /configs.tar.bz2 
  echo "root:${password}" | chpasswd
EOT
# ----- \begin{non-root-user-section} --------------------------
RUN <<EOT bash
  adduser --quiet --home /home/${user} --shell /bin/bash --uid ${uid} --disabled-password --gecos "${gecos}" --add_extra_groups ${user}
  echo "${user}:${password}" | chpasswd
  echo -e "\necho \"Your password is: ${password}\" \n" >> /home/${user}/.bashrc
EOT


# Set up USER and WORKDIR; set up DISPLAY for that USER
USER ${user}
WORKDIR /home/${user}
ENV DISPLAY=${DISPLAY}
# ----- \end{non-root-user-section} ----------------------------

# Run bash on the container's start
CMD bash
