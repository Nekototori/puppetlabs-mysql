require File.expand_path(File.join(File.dirname(__FILE__), '..', 'mysql'))
Puppet::Type.type(:mysql_user).provide(:mysql, parent: Puppet::Provider::Mysql) do
  desc 'manage users for a mysql database.'
  commands mysql: 'mysql'

  # Build a property_hash containing all the discovered information about MySQL
  # users.
  def self.instances
    users = mysql([defaults_file, '-NBe',
                   "SELECT CONCAT(User, '@',Host) AS User FROM mysql.user"].compact).split("\n")
    # To reduce the number of calls to MySQL we collect all the properties in
    # one big swoop.
    # We also want to ensure the mysql service is running at time of query, otherwise the whole catalog explodes.
    if File.exist?('/var/lib/mysql/mysql.sock')
    users.map do |name|
      if mysqld_version.nil?
        ## Default ...
        # rubocop:disable Metrics/LineLength
        query = "SELECT MAX_USER_CONNECTIONS, MAX_CONNECTIONS, MAX_QUESTIONS, MAX_UPDATES, SSL_TYPE, SSL_CIPHER, X509_ISSUER, X509_SUBJECT, PASSWORD /*!50508 , PLUGIN */ FROM mysql.user WHERE CONCAT(user, '@', host) = '#{name}'"
      elsif (mysqld_type == 'mysql' || mysqld_type == 'percona') && Puppet::Util::Package.versioncmp(mysqld_version, '5.7.6') >= 0
        query = "SELECT MAX_USER_CONNECTIONS, MAX_CONNECTIONS, MAX_QUESTIONS, MAX_UPDATES, SSL_TYPE, SSL_CIPHER, X509_ISSUER, X509_SUBJECT, AUTHENTICATION_STRING, PLUGIN FROM mysql.user WHERE CONCAT(user, '@', host) = '#{name}'"
      else
        query = "SELECT MAX_USER_CONNECTIONS, MAX_CONNECTIONS, MAX_QUESTIONS, MAX_UPDATES, SSL_TYPE, SSL_CIPHER, X509_ISSUER, X509_SUBJECT, PASSWORD /*!50508 , PLUGIN */ FROM mysql.user WHERE CONCAT(user, '@', host) = '#{name}'"
      end
      @max_user_connections, @max_connections_per_hour, @max_queries_per_hour,
      @max_updates_per_hour, ssl_type, ssl_cipher, x509_issuer, x509_subject,
      @password, @plugin = mysql([defaults_file, '-NBe', query].compact).split(%r{\s})
      @tls_options = parse_tls_options(ssl_type, ssl_cipher, x509_issuer, x509_subject)
      # rubocop:enable Metrics/LineLength
      new(name: name,
          ensure: :present,
          password_hash: @password,
          plugin: @plugin,
          max_user_connections: @max_user_connections,
          max_connections_per_hour: @max_connections_per_hour,
          max_queries_per_hour: @max_queries_per_hour,
          max_updates_per_hour: @max_updates_per_hour,
          tls_options: @tls_options)
    end
  end
end

  # We iterate over each mysql_user entry in the catalog and compare it against
  # the contents of the property_hash generated by self.instances
  def self.prefetch(resources)
    users = instances
    # rubocop:disable Lint/AssignmentInCondition
    resources.keys.each do |name|
      if provider = users.find { |user| user.name == name }
        resources[name].provider = provider
      end
    end
    # rubocop:enable Lint/AssignmentInCondition
  end

  def create
    merged_name              = @resource[:name].sub('@', "'@'")
    password_hash            = @resource.value(:password_hash)
    plugin                   = @resource.value(:plugin)
    max_user_connections     = @resource.value(:max_user_connections) || 0
    max_connections_per_hour = @resource.value(:max_connections_per_hour) || 0
    max_queries_per_hour     = @resource.value(:max_queries_per_hour) || 0
    max_updates_per_hour     = @resource.value(:max_updates_per_hour) || 0
    tls_options              = @resource.value(:tls_options) || ['NONE']

    # Use CREATE USER to be compatible with NO_AUTO_CREATE_USER sql_mode
    # This is also required if you want to specify a authentication plugin
    if !plugin.nil?
      if plugin == 'sha256_password' && !password_hash.nil?
        mysql([defaults_file, system_database, '-e', "CREATE USER '#{merged_name}' IDENTIFIED WITH '#{plugin}' AS '#{password_hash}'"].compact)
      else
        mysql([defaults_file, system_database, '-e', "CREATE USER '#{merged_name}' IDENTIFIED WITH '#{plugin}'"].compact)
      end
      @property_hash[:ensure] = :present
      @property_hash[:plugin] = plugin
    else
      mysql([defaults_file, system_database, '-e', "CREATE USER '#{merged_name}' IDENTIFIED BY PASSWORD '#{password_hash}'"].compact)
      @property_hash[:ensure] = :present
      @property_hash[:password_hash] = password_hash
    end
    # rubocop:disable Metrics/LineLength
    mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO '#{merged_name}' WITH MAX_USER_CONNECTIONS #{max_user_connections} MAX_CONNECTIONS_PER_HOUR #{max_connections_per_hour} MAX_QUERIES_PER_HOUR #{max_queries_per_hour} MAX_UPDATES_PER_HOUR #{max_updates_per_hour}"].compact)
    # rubocop:enable Metrics/LineLength
    @property_hash[:max_user_connections] = max_user_connections
    @property_hash[:max_connections_per_hour] = max_connections_per_hour
    @property_hash[:max_queries_per_hour] = max_queries_per_hour
    @property_hash[:max_updates_per_hour] = max_updates_per_hour

    merged_tls_options = tls_options.join(' AND ')
    if ((mysqld_type == 'mysql' || mysqld_type == 'percona') && Puppet::Util::Package.versioncmp(mysqld_version, '5.7.6') >= 0) ||
       (mysqld_type == 'mariadb' && Puppet::Util::Package.versioncmp(mysqld_version, '10.2.0') >= 0)
      mysql([defaults_file, system_database, '-e', "ALTER USER '#{merged_name}' REQUIRE #{merged_tls_options}"].compact)
    else
      mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO '#{merged_name}' REQUIRE #{merged_tls_options}"].compact)
    end
    @property_hash[:tls_options] = tls_options

    exists? ? (return true) : (return false)
  end

  def destroy
    merged_name = @resource[:name].sub('@', "'@'")
    mysql([defaults_file, system_database, '-e', "DROP USER '#{merged_name}'"].compact)

    @property_hash.clear
    exists? ? (return false) : (return true)
  end

  def exists?
    @property_hash[:ensure] == :present || false
  end

  ##
  ## MySQL user properties
  ##

  # Generates method for all properties of the property_hash
  mk_resource_methods

  def password_hash=(string)
    merged_name = self.class.cmd_user(@resource[:name])

    # We have a fact for the mysql version ...
    if mysqld_version.nil?
      # default ... if mysqld_version does not work
      mysql([defaults_file, system_database, '-e', "SET PASSWORD FOR #{merged_name} = '#{string}'"].compact)
    elsif (mysqld_type == 'mysql' || mysqld_type == 'percona') && Puppet::Util::Package.versioncmp(mysqld_version, '5.7.6') >= 0
      raise ArgumentError, 'Only mysql_native_password (*ABCD...XXX) hashes are supported' unless string =~ %r{^\*}
      mysql([defaults_file, system_database, '-e', "ALTER USER #{merged_name} IDENTIFIED WITH mysql_native_password AS '#{string}'"].compact)
    else
      mysql([defaults_file, system_database, '-e', "SET PASSWORD FOR #{merged_name} = '#{string}'"].compact)
    end

    (password_hash == string) ? (return true) : (return false)
  end

  def max_user_connections=(int)
    merged_name = self.class.cmd_user(@resource[:name])
    mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO #{merged_name} WITH MAX_USER_CONNECTIONS #{int}"].compact).chomp

    (max_user_connections == int) ? (return true) : (return false)
  end

  def max_connections_per_hour=(int)
    merged_name = self.class.cmd_user(@resource[:name])
    mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO #{merged_name} WITH MAX_CONNECTIONS_PER_HOUR #{int}"].compact).chomp

    (max_connections_per_hour == int) ? (return true) : (return false)
  end

  def max_queries_per_hour=(int)
    merged_name = self.class.cmd_user(@resource[:name])
    mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO #{merged_name} WITH MAX_QUERIES_PER_HOUR #{int}"].compact).chomp

    (max_queries_per_hour == int) ? (return true) : (return false)
  end

  def max_updates_per_hour=(int)
    merged_name = self.class.cmd_user(@resource[:name])
    mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO #{merged_name} WITH MAX_UPDATES_PER_HOUR #{int}"].compact).chomp

    (max_updates_per_hour == int) ? (return true) : (return false)
  end

  def tls_options=(array)
    merged_name = self.class.cmd_user(@resource[:name])
    merged_tls_options = array.join(' AND ')
    if ((mysqld_type == 'mysql' || mysqld_type == 'percona') && Puppet::Util::Package.versioncmp(mysqld_version, '5.7.6') >= 0) ||
       (mysqld_type == 'mariadb' && Puppet::Util::Package.versioncmp(mysqld_version, '10.2.0') >= 0)
      mysql([defaults_file, system_database, '-e', "ALTER USER #{merged_name} REQUIRE #{merged_tls_options}"].compact)
    else
      mysql([defaults_file, system_database, '-e', "GRANT USAGE ON *.* TO #{merged_name} REQUIRE #{merged_tls_options}"].compact)
    end

    (tls_options == array) ? (return true) : (return false)
  end

  def self.parse_tls_options(ssl_type, ssl_cipher, x509_issuer, x509_subject)
    if ssl_type == 'ANY'
      ['SSL']
    elsif ssl_type == 'X509'
      ['X509']
    elsif ssl_type == 'SPECIFIED'
      options = []
      options << "CIPHER #{ssl_cipher}" if !ssl_cipher.nil? && !ssl_cipher.empty?
      options << "ISSUER #{x509_issuer}" if !x509_issuer.nil? && !x509_issuer.empty?
      options << "SUBJECT #{x509_subject}" if !x509_subject.nil? && !x509_subject.empty?
      options
    else
      ['NONE']
    end
  end
end
