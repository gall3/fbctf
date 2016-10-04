#!/bin/bash

# Facebook CTF: Funciones para los scripts de aprovisionamiento
#

function log() {
  echo "[+] $1"
}

function error_log() {
  RED='\033[0;31m'
  NORMAL='\033[0m'
  echo "${RED} [!] $1 ${NORMAL}"
}

function ok_log() {
  GREEN='\033[0;32m'
  NORMAL='\033[0m'
  echo "${GREEN} [+] $1 ${NORMAL}"
}

function dl() {
  local __url=$1
  local __dest=$2

  if [ -n "$(which wget)" ]; then
    sudo wget -q "$__url" -O "$__dest"
  else
    sudo curl -s "$__url" -o "$__dest"
  fi
}

function package() {
  if [[ -n "$(dpkg --get-selections | grep $1)" ]]; then
    log "$1 ya está instalado. Omitiendo."
  else
    log "Instalando $1"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install $1 -y --no-install-recommends
  fi
}

function install_unison() {
  log "Instalando Unison 2.48.4"
  cd /
  curl -sL https://www.archlinux.org/packages/extra/x86_64/unison/download/ | sudo tar Jx
}

function repo_osquery() {
  log "Añadiendo las claves del repositorio osquery"
  sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 1484120AC4E9F8A1A577AEEE97A80C63C9D8B80B
  sudo add-apt-repository "deb [arch=amd64] https://osquery-packages.s3.amazonaws.com/trusty trusty main"
}

function repo_mycli() {
  log "Añadiendo las claves del repositorio MyCLI"
  curl -s https://packagecloud.io/gpg.key | sudo apt-key add -
  package apt-transport-https
  echo "deb https://packagecloud.io/amjith/mycli/ubuntu/ trusty main" | sudo tee -a /etc/apt/sources.list
}

function install_mysql() {
  local __pwd=$1

  log "Instalando MySQL"

  echo "mysql-server-5.5 mysql-server/root_password password $__pwd" | sudo debconf-set-selections
  echo "mysql-server-5.5 mysql-server/root_password_again password $__pwd" | sudo debconf-set-selections
  package mysql-server

  # Debería iniciar automáticamente, pero por si acaso
  sudo service mysql restart
}

function set_motd() {
  local __path=$1

  # Si el cloudguest MOTD existe, deshabilitarlo
  if [[ -f /etc/update-motd.d/51/cloudguest ]]; then
    sudo chmod -x /etc/update-motd.d/51-cloudguest
  fi

  sudo cp "$__path/extra/motd-ctf.sh" /etc/update-motd.d/10-help-text
}

function run_grunt() {
  local __path=$1
  local __mode=$2

  cd "$__path"
  grunt

  # grunt revisa la VM y se asegura de que los archivos js
  # están correctamente actualizados cuando se despliega 'remotamente' con unison.
  # la revisión de grunt emplea hasta 5 segundos en actualizar un archivo,
  # así que hay que darle tiempo cuando se hace el despliegue.
  if [[ $__mode = "dev" ]]; then
    grunt watch &
  fi
}

function self_signed_cert() {
  local __csr="/etc/nginx/certs/dev.csr"
  local __devcert=$1
  local __devkey=$2

  sudo openssl req -nodes -newkey rsa:2048 -keyout "$__devkey" -out "$__csr" -subj "/O=Facebook CTF"
  sudo openssl x509 -req -days 365 -in "$__csr" -signkey "$__devkey" -out "$__devcert"
}

function letsencrypt_cert() {
  local __email=$3
  local __domain=$4
  local __docker=$5

  dl "https://dl.eff.org/certbot-auto" /usr/bin/certbot-auto
  sudo chmod a+x /usr/bin/certbot-auto

  if [[ $__email == "none" ]]; then
    read -p ' -> Cuál es el email para recuperar el certificado SSL? ' __myemail
  else
    __myemail=$__email
  fi
  if [[ $__domain == "none" ]]; then
    read -p ' -> Cuál es el dominio para el certificado SSL? ' __mydomain
  else
    __mydomain=$__domain
  fi

  if [[ $__docker = true ]]; then
    cat <<- EOF > /root/tmp/certbot.sh
		#!/bin/bash
		if [[ ! ( -d /etc/letsencrypt && "\$(ls -A /etc/letsencrypt)" ) ]]; then
		    /usr/bin/certbot-auto certonly -n --agree-tos --standalone --standalone-supported-challenges tls-sni-01 -m "$__myemail" -d "$__mydomain"
		fi
		sudo ln -sf "/etc/letsencrypt/live/$__mydomain/fullchain.pem" "$1"
		sudo ln -sf "/etc/letsencrypt/live/$__mydomain/privkey.pem" "$2"
EOF
    sudo chmod +x /root/tmp/certbot.sh
  else
    /usr/bin/certbot-auto certonly -n --agree-tos --standalone --standalone-supported-challenges tls-sni-01 -m "$__myemail" -d "$__mydomain"
    sudo ln -s "/etc/letsencrypt/live/$__mydomain/fullchain.pem" "$1" || true
    sudo ln -s "/etc/letsencrypt/live/$__mydomain/privkey.pem" "$2" || true
  fi
}

function own_cert() {
  local __owncert=$1
  local __ownkey=$2

  read -p ' -> Ubicación del archivo de certificado SSL? ' __mycert
  read -p ' -> Ubicación del archivo de claves de certificado SSL? ' __mykey
  sudo cp "$__mycert" "$__owncert"
  sudo cp "$__mykey" "$__ownkey"
}

function install_nginx() {
  local __path=$1
  local __mode=$2
  local __certs=$3
  local __email=$4
  local __domain=$5
  local __docker=$6

  local __certs_path="/etc/nginx/certs"

  log "Desplegando certificados"
  sudo mkdir -p "$__certs_path"

  if [[ $__mode = "dev" ]]; then
    local __cert="$__certs_path/dev.crt"
    local __key="$__certs_path/dev.key"
    self_signed_cert "$__cert" "$__key"
  elif [[ $__mode = "prod" ]]; then
    local __cert="$__certs_path/fbctf.crt"
    local __key="$__certs_path/fbctf.key"
    case "$__certs" in
      self)
        self_signed_cert "$__cert" "$__key"
      ;;
      own)
        own_cert "$__cert" "$__key"
      ;;
      certbot)
        if [[ $__docker = true ]]; then
          self_signed_cert "$__cert" "$__key"
        fi
        letsencrypt_cert "$__cert" "$__key" "$__email" "$__domain" "$__docker"
      ;;
      *)
        error_log "Tipo de certificado no reconocido"
        exit 1
      ;;
    esac
  fi

  # Nos aseguramos de instalar nginx después del certificado porque se usamos
  # letsencrypt, necesitaremos estar seguros de que no hay nada escuchando en ese puerto
  package nginx

  __dhparam="/etc/nginx/certs/dhparam.pem"
  sudo openssl dhparam -out "$__dhparam" 2048

  cat "$__path/extra/nginx.conf" | sed "s|CTFPATH|$__path/src|g" | sed "s|CER_FILE|$__cert|g" | sed "s|KEY_FILE|$__key|g" | sed "s|DHPARAM_FILE|$__dhparam|g" | sudo tee /etc/nginx/sites-available/fbctf.conf

  sudo rm -f /etc/nginx/sites-enabled/default
  sudo ln -sf /etc/nginx/sites-available/fbctf.conf /etc/nginx/sites-enabled/fbctf.conf

  # Reiniciar nginx
  sudo nginx -t
  sudo service nginx restart
}

# TODO: Deberíamos dividir esta función en dos: una cuando el repositorio esté añadido y
# otra cuando el repositorio esté instalado
function install_hhvm() {
  local __path=$1

  package software-properties-common

  log "Añadiendo clave HHVM"
  sudo apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0x5a16e7281be7a449

  log "Añadiendo repositorio HHVM"
  sudo add-apt-repository "deb http://dl.hhvm.com/ubuntu $(lsb_release -sc) main"

  log "Instalando HHVM"
  sudo apt-get update
  # Instalando el paquete también instalamos sus dependencias
  package hhvm
  # La versión 3.15 de HHVM no funciona correctamente con FBCTF. Ver: https://github.com/facebook/hhvm/issues/7333
  # Hasta que se arregle este problema, instalar manualmente la versión más próxima a la 3.14.5
  sudo apt-get remove hhvm -y
  # Limpiar archivos antiguos
  sudo rm -Rf /var/run/hhvm/*
  local __package="hhvm_3.14.5~$(lsb_release -sc)_amd64.deb"
  dl "http://dl.hhvm.com/ubuntu/pool/main/h/hhvm/$__package" "/tmp/$__package"
  sudo dpkg -i "/tmp/$__package"

  log "Copiando la configuración HHVM"
  cat "$__path/extra/hhvm.conf" | sed "s|CTFPATH|$__path/|g" | sudo tee /etc/hhvm/server.ini

  log "HHVM como sistema PHP"
  sudo /usr/bin/update-alternatives --install /usr/bin/php php /usr/bin/hhvm 60

  log "Habilitando HHVM para iniciarse por defecto"
  sudo update-rc.d hhvm defaults

  log "Reiniciar HHVM"
  sudo service hhvm restart
}

function hhvm_performance() {
  local __path=$1

  log "Habilitando el modo Repoautoritativo de HHVM"
  sudo hhvm-repo-mode enable "$__path"
  sudo chown www-data:www-data /var/run/hhvm/hhvm.hhbc
}

function install_composer() {
  local __path=$1

  log "Instalando composer"
  cd $__path
  curl -sS https://getcomposer.org/installer | php
  php composer.phar install
  sudo mv composer.phar /usr/bin
  sudo chmod +x /usr/bin/composer.phar
}

function import_empty_db() {
  local __u="ctf"
  local __p="ctf"
  local __user=$1
  local __pwd=$2
  local __db=$3
  local __path=$4
  local __mode=$5

  log "Creando la base de datos - $__db"
  mysql -u "$__user" --password="$__pwd" -e "CREATE DATABASE IF NOT EXISTS \`$__db\`;"

  log "Importando esquema..."
  mysql -u "$__user" --password="$__pwd" "$__db" -e "source $__path/database/schema.sql;"
  log "Importando países..."
  mysql -u "$__user" --password="$__pwd" "$__db" -e "source $__path/database/countries.sql;"
  log "Importando logos..."
  mysql -u "$__user" --password="$__pwd" "$__db" -e "source $__path/database/logos.sql;"

  log "Creando usuario..."
  mysql -u "$__user" --password="$__pwd" -e "CREATE USER '$__u'@'localhost' IDENTIFIED BY '$__p';" || true # no falla si el usuario existe
  mysql -u "$__user" --password="$__pwd" -e "GRANT ALL PRIVILEGES ON \`$__db\`.* TO '$__u'@'localhost';"
  mysql -u "$__user" --password="$__pwd" -e "FLUSH PRIVILEGES;"

  log "Archivo de conexión de la DB"
  cat "$__path/extra/settings.ini.example" | sed "s/DATABASE/$__db/g" | sed "s/MYUSER/$__u/g" | sed "s/MYPWD/$__p/g" > "$__path/settings.ini"

  local PASSWORD
  log "Añadiendo usuario administrador por defecto"
  if [[ $__mode = "dev" ]]; then
    PASSWORD='password'
  else
    PASSWORD=$(head -c 500 /dev/urandom | md5sum | cut -d" " -f1)
  fi

  set_password "$PASSWORD" "$__user" "$__pwd" "$__db" "$__path"
  log "Creado el usuario admin con la contraseña $PASSWORD"
}

function set_password() {
  local __admin_pwd=$1
  local __user=$2
  local __db_pwd=$3
  local __db=$4
  local __path=$5

  HASH=$(hhvm -f "$__path/extra/hash.php" "$__admin_pwd")
  # En primer lugar, tratamos de eliminar el usuario admin existente
  mysql -u "$__user" --password="$__db_pwd" "$__db" -e "DELETE FROM teams WHERE name='admin' AND admin=1"
  # A continuación insertarmos un nuevo usuario admin con ID 1 (en cualquier caso, conviene comprobarlo en la BD)
  mysql -u "$__user" --password="$__db_pwd" "$__db" -e "INSERT INTO teams (id, name, password_hash, admin, protected, logo, created_ts) VALUES (1, 'admin', '$HASH', 1, 1, 'admin', NOW());"
  if [[ $? -eq 0 ]]; then
  	echo "La nueva contraseña para el usuario admin es $__admin_pwd"
  fi
  
}

function update_repo() {
  local __mode=$1
  local __code_path=$2
  local __ctf_path=$3

  if pgrep -x "grunt" > /dev/null
  then
    killall -9 grunt
  fi

  echo "[+] Extrayendo del repositorio remoto"
  git pull --rebase https://github.com/facebook/fbctf.git

  echo "[+] Iniciando sincronización con $__ctf_path"
  if [[ "$__code_path" != "$__ctf_path" ]]; then
      [[ -d "$__ctf_path" ]] || sudo mkdir -p "$__ctf_path"

      echo "[+] Copiando todo el código a la carpeta de destino"
      sudo rsync -a --exclude node_modules --exclude vendor "$__code_path/" "$__ctf_path/"

      # This is because sync'ing files is done with unison
      if [[ "$__mode" == "dev" ]]; then
          echo "[+] Establecidendo permisos"
          sudo chmod -R 777 "$__ctf_path/"
      fi
  fi

  cd "$__ctf_path"
  composer.phar install

  run_grunt "$__ctf_path" "$__mode"
}