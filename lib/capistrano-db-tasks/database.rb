module Database
  class Base
    attr_accessor :config, :output_file
    def initialize(cap_instance)
      @cap = cap_instance
    end

    def mysql?
      @config['adapter'] =~ /^mysql/
    end

    def postgresql?
      %w(postgresql pg).include? @config['adapter']
    end

    def credentials
      if mysql?
        " -u #{@config['username']} " + (password_present? ? " -p\"#{@config['password']}\" " : '') + (@config['host'] ? " -h #{@config['host']}" : '') + (@config['socket'] ? " -S#{@config['socket']}" : '')
      elsif postgresql?
        " -U #{@config['username']} " + (@config['host'] ? " -h #{@config['host']}" : '')
      end
    end

    def database
      @config['database']
    end

    def current_time
      Time.now.strftime("%Y-%m-%d-%H%M%S")
    end

    def output_file
      @output_file ||= "db/#{database}_#{current_time}.sql.bz2"
    end


  private

    def dump_cmd
      if mysql?
        "mysqldump #{credentials} #{database} --lock-tables=false"
      elsif postgresql?
        "#{postgres_password_prefix} pg_dump #{credentials} -c -O #{database}"
      end
    end

    def import_cmd(file)
      if mysql?
        "#{client_cmd} #{credentials} -D #{database} < #{file}"
      elsif postgresql?
        "#{client_cmd} #{credentials} #{database} < #{file}"
      end
    end

    def client_cmd
      case
      when mysql? then "mysql"
      when postgresql? then postgres_password_prefix + "psql"
      end
    end

    def postgres_password_prefix
      password_present? ? "PGPASSWORD=#{@config['password']} " : ""
    end

    def password_present?
      @config['password']
    end

  end

  class Remote < Base
    def initialize(cap_instance)
      super(cap_instance)
      # YAML::ENGINE.yamler = 'syck'
      @cap.run("cat #{@cap.current_path}/config/database.yml") { |c, s, d| @config = YAML.load(d)[@cap.rails_env] }
    end

    def dump
      @cap.run "cd #{@cap.current_path} && #{dump_cmd} | bzip2 - - > #{output_file}"
      self
    end

    def download(local_file = "#{output_file}")
      remote_file = "#{@cap.current_path}/#{output_file}"
      @cap.get remote_file, local_file
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, '.bz2'))
      # @cap.run "cd #{@cap.current_path} && bunzip2 -f #{file} && RAILS_ENV=#{@cap.rails_env} bundle exec rake db:drop db:create && #{import_cmd(unzip_file)}"
      @cap.run "cd #{@cap.current_path} && bunzip2 -f #{file} && RAILS_ENV=#{@cap.rails_env} && #{import_cmd(unzip_file)}"
      @cap.run("cd #{@cap.current_path} && rm #{unzip_file}") if cleanup
    end
  end

  class Local < Base
    def initialize(cap_instance)
      super(cap_instance)
      @config = YAML.load_file(File.join('config', 'database.yml'))[@cap.local_rails_env]
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, '.bz2'))
      # system("bunzip2 -f #{file} && bundle exec rake db:drop db:create && #{import_cmd(unzip_file)} && bundle exec rake db:migrate")
      system("bunzip2 -f #{file} && #{import_cmd(unzip_file)}")
      File.unlink(unzip_file) if cleanup
    end

    def dump
      system "#{dump_cmd} | bzip2 - - > #{output_file}"
      self
    end

    def upload
      remote_file = "#{@cap.current_path}/#{output_file}"
      @cap.upload output_file, remote_file
    end
  end


  class << self
    def check(local_db, remote_db)
      unless (local_db.mysql? && remote_db.mysql?) || (local_db.postgresql? && remote_db.postgresql?)
        raise 'Only mysql or postgresql on remote and local server is supported'
      end
    end

    def remote_to_local(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      remote_db.dump.download
      local_db.load(remote_db.output_file, instance.fetch(:db_local_clean))
    end

    def local_to_remote(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      local_db.dump.upload
      remote_db.load(local_db.output_file, instance.fetch(:db_local_clean))
    end
  end

end
