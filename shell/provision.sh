VAGRANT_HOME="/home/vagrant"
PROVISION_SRC_DIR="/vagrant"
CONFIG_SRC_DIR="${PROVISION_SRC_DIR}/files/config"
AUGLENS_DIR="${PROVISION_SRC_DIR}/files/augeas/lenses"
AUGCONF_DIR="${PROVISION_SRC_DIR}/files/augeas/config"
AUGTOOL="augtool -I ${AUGLENS_DIR}"
PHP5_MOD_CONF_DIR="/etc/php5/mods-available"
RUBY_VERSION="2.1.3"
HAVE_SSL=0

echo "Provisioning"
echo "============"

# We don't want debconf prompts
export DEBIAN_FRONTEND=noninteractive

echo "Retrieving package lists"
apt-get -y update >/dev/null

echo "Installing base packages"
apt-get -y install software-properties-common python-software-properties build-essential git curl augeas-tools augeas-lenses >/dev/null 2>/dev/null

echo "Adding PPAs"
yes | add-apt-repository ppa:george-edison55/openssl-heartbleed-fix >/dev/null 2>/dev/null
yes | add-apt-repository ppa:ondrej/php5-5.6 >/dev/null 2>/dev/null
yes | add-apt-repository ppa:ondrej/nginx >/dev/null 2>/dev/null
yes | add-apt-repository ppa:ondrej/mariadb-5.5 >/dev/null 2>/dev/null
yes | add-apt-repository ppa:chris-lea/redis-server >/dev/null 2>/dev/null
apt-get -y update >/dev/null

# Currently does not bundle npm (?!) and conflicts with npm package, sad...
#add-apt-repository ppa:chris-lea/node.js >/dev/null 2>/dev/null

echo "Upgrading present packages"
apt-get -y upgrade >/dev/null 2>/dev/null

which rvm >/dev/null
if [[ $? != "0" ]]; then
    echo "Installing RVM with ruby version: ${RUBY_VERSION}"
    curl -sSL https://get.rvm.io | bash -s stable >/dev/null 2>/dev/null

    [ -s /etc/profile.d/rvm.sh ] && source /etc/profile.d/rvm.sh
    rvm install ${RUBY_VERSION} >/dev/null 2>/dev/null
    rvm --default use ${RUBY_VERSION} >/dev/null  2>/dev/null
    echo "gem: --no-rdoc --no-ri" > $VAGRANT_HOME/.gemrc
    printf "rvm_autoupdate_flag=0\nrvm_auto_reload_flag=2" > $VAGRANT_HOME/.rvmrc
    chown vagrant:vagrant $VAGRANT_HOME/.gemrc
    rm -f $VAGRANT_HOME/.profile
    rm -f $VAGRANT_HOME/.z*
    yes | gem install bundler --no-rdoc --no-ri >/dev/null 2>/dev/null
    rvm cleanup all >/dev/null
else
    echo "Skipping RVM installation -> already installed"
fi

echo "Installing libraries"
apt-get -y install libpcre3 libevent-2.0 libcurl3 librtmp0 libp11-kit0 libtasn1-6 libgcrypt11 libgpg-error0 libldap-2.4-2 libkrb5-3 libidn11 >/dev/null 2>/dev/null

echo "Installing nginx and PHP"
apt-get -y install nginx php5-common php5-cli php5-fpm php5-mcrypt php5-gd php5-ldap php5-curl php5-intl php5-mysqlnd php5-redis php5-sqlite php5-xmlrpc php5-xsl php5-xdebug php-pear php5-dev >/dev/null 2>/dev/null

if [ ! -f "${PHP5_MOD_CONF_DIR}/pecl_http" ]; then
    echo "Compiling and installing PECL extensions"
    apt-get -y install libpcre3-dev libevent-dev libcurl4-openssl-dev zlib1g-dev >/dev/null 2>/dev/null

    yes | pecl install raphf >/dev/null
    yes | pecl install propro >/dev/null
    printf "; configuration for php raphf module\n; priority=10\nextension=raphf.so" > /etc/php5/mods-available/raphf.ini
    printf "; configuration for php propro module\n; priority=10\nextension=propro.so" > /etc/php5/mods-available/propro.ini
    php5enmod raphf >/dev/null 2>/dev/null
    php5enmod propro >/dev/null 2>/dev/null

    yes | pecl install pecl_http >/dev/null
    yes | pecl install xhprof-beta >/dev/null
else
    echo "Updating PECL extensions"
fi

yes | pecl upgrade >/dev/null

echo "Configuring PHP"
cp -f $CONFIG_SRC_DIR/php5/*.ini $PHP5_MOD_CONF_DIR >/dev/null
for INI_FILE in `\ls $PHP5_MOD_CONF_DIR`; do
    php5enmod `echo "${INI_FILE}" | awk '{ sub(/\.ini$/, ""); print }'` >/dev/null 2>/dev/null
done
$AUGTOOL -f $AUGCONF_DIR/php5.augconf >/dev/null
service php5-fpm restart >/dev/null

COMPOSER_DST="/usr/local/bin/composer"
if [ ! -x "${COMPOSER_DST}" ]; then
    echo "Installing composer"
    curl -sS https://getcomposer.org/installer | php >/dev/null 2>/dev/null
    mv composer.phar $COMPOSER_DST
else
    echo "Updating composer"
    composer self-update >/dev/null
fi

chown -R vagrant:vagrant $VAGRANT_HOME/.composer >/dev/null 2>/dev/null

echo "Configuring nginx"
cp -f $CONFIG_SRC_DIR/nginx_default.conf /etc/nginx/sites-available/default

if [ -f $PROVISION_SRC_DIR/files/ssl/server.crt -a -f $PROVISION_SRC_DIR/files/ssl/server.key ]; then
    HAVE_SSL=1
    echo "Copying SSL certificate and key files"
    mkdir -p /etc/ssl/server >/dev/null
    cp -raf $PROVISION_SRC_DIR/files/ssl/* /etc/ssl/server >/dev/null
fi

if [[ "${HAVE_SSL}" == "1" ]]; then
    echo "Configuring nginx for SSL"
    echo "listen 443 default_server ssl;" > /etc/nginx/ssl_config
    echo "ssl_certificate /etc/ssl/server/server.crt;" >> /etc/nginx/ssl_config
    echo "ssl_certificate_key /etc/ssl/server/server.key;" >> /etc/nginx/ssl_config
else
    echo "No SSL certificates found -> not enabling SSL"
    echo "" > /etc/nginx/ssl_config
fi
$AUGTOOL -f $AUGCONF_DIR/nginx.augconf >/dev/null
service nginx restart >/dev/null

echo "Installing MariaDB"
apt-get -y install mariadb-server >/dev/null 2>/dev/null

echo "Configuring MariaDB"
$AUGTOOL -f $AUGCONF_DIR/mysql.augconf >/dev/null
service mysql restart >/dev/null
mysql -u root -e "GRANT ALL ON *.* TO 'root'@'' WITH GRANT OPTION; FLUSH PRIVILEGES"

echo "Updating gems"
yes | gem update >/dev/null 2>/dev/null

if [ -z "`rvm gemset list | grep mailcatcher`" ]; then
    echo "Installing Mailcatcher"
    rvm default@mailcatcher --create do gem install mailcatcher >/dev/null 2>/dev/null
    rvm wrapper default@mailcatcher --no-prefix mailcatcher catchmail >/dev/null 2>/dev/null
    rvm default@mailcatcher do gem install i18n -v 0.6.11 >/dev/null 2>/dev/null
    rvm default@mailcatcher do gem uninstall i18n -Ix --version '>0.6.11' >/dev/null 2>/dev/null

    cp -f $CONFIG_SRC_DIR/mailcatcher.upstart.conf /etc/init/mailcatcher.conf >/dev/null
    service mailcatcher start >/dev/null 2>/dev/null

    echo "Installing nullmailer"
    apt-get -y install nullmailer >/dev/null 2>/dev/null

    echo "Configuring nullmailer"
    echo "127.0.0.1 smtp --port=1025" > /etc/nullmailer/remotes
else
    echo "Updating mailcatcher"
    rvm default@mailcatcher do gem update mailcatcher >/dev/null
fi

echo "Installing additional packages: nodejs, npm, redis-server"
apt-get -y install nodejs npm redis-server >/dev/null 2>/dev/null

if [ -z "`npm -g list | grep grunt-cli`" ]; then
    echo "Installing Grunt"
    npm -g install grunt-cli >/dev/null 2>/dev/null
else
    echo "Updating npm packages"
    npm -g update >/dev/null 2>/dev/null
fi

echo "Installing supplemental tools: htop, tree, mercurial"
apt-get -y install htop tree mercurial >/dev/null 2>/dev/null

echo "Copying dotfiles"
cp -f $PROVISION_SRC_DIR/files/dot/.* $VAGRANT_HOME/ >/dev/null 2>/dev/null
cp -f $PROVISION_SRC_DIR/files/dot/.* /root >/dev/null 2>/dev/null
chown vagrant:vagrant $VAGRANT_HOME/.* >/dev/null 2>/dev/null
chown root:root /root/.* >/dev/null 2>/dev/null

if [ -d $PROVISION_SRC_DIR/files/ssh -a -f $PROVISION_SRC_DIR/files/ssh/vagrant_private_rsa.pub ]; then
    echo "Adding additional Vagrant SSH pubkey"
    cd $VAGRANT_HOME/.ssh
    rm authorized_keys >/dev/null
    wget --no-check-certificate 'https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub' -O authorized_keys >/dev/null  2>/dev/null
    echo -n "\n" >> $VAGRANT_HOME/.ssh/authorized_keys
    cat $PROVISION_SRC_DIR/files/ssh/vagrant_private_rsa.pub >> $VAGRANT_HOME/.ssh/authorized_keys >/dev/null
    chmod 600 $VAGRANT_HOME/.ssh/authorized_keys >/dev/null
    chown -R vagrant $VAGRANT_HOME/.ssh >/dev/null
    cd $VAGRANT_HOME
fi

echo "Cleaning up"
apt-get -y autoremove >/dev/null
apt-get -y clean >/dev/null
rvm cleanup all >/dev/null

echo "Defragmenting root disk"
if which e4defrag >/dev/null; then
    e4defrag `mount | awk '/^(.*)\s+on\s+\/\s+type\s+ext4/ { print $1 }'` >/dev/null 2>/dev/null
fi

echo "Zeroing remaining disk space"
dd if=/dev/zero of=/EMPTY bs=1M >/dev/null 2>/dev/null
rm -f /EMPTY >/dev/null

echo "================="
echo "Done provisioning"
