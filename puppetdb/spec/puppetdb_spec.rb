require 'timeout'
require 'json'
require 'open3'
require 'rspec'
require 'net/http'

describe 'puppetdb container specs' do
  include Helpers

  VOLUMES = [
    'pgdata'
  ]

  def count_database(container, database)
    cmd = "docker exec #{container} psql -t --username=puppetdb --command=\"SELECT count(datname) FROM pg_database where datname = '#{database}'\""
    run_command(cmd)[:stdout].strip
  end

  def wait_on_postgres_db(container, database)
    Timeout::timeout(120) do
      while count_database(container, database) != '1'
        sleep(1)
      end
    end
  rescue Timeout::Error
    STDOUT.puts("database #{database} never created")
    raise
  end

  def run_postgres_container
    image_name = 'postgres:9.6'
    run_command("docker pull #{image_name}")

    data_mount = ''
    if !!File::ALT_SEPARATOR
      data_mount = "--volume #{ENV['VOLUME_ROOT']}/pgdata:/var/lib/postgresql/data"
    end

    postgres_custom_source = File.join(File.expand_path(__dir__), '..', 'postgres-custom')
    result = run_command("docker run --detach \
          --env POSTGRES_PASSWORD=puppetdb \
          --env POSTGRES_USER=puppetdb \
          --env POSTGRES_DB=puppetdb \
          --name postgres \
          --network #{@network} \
          --hostname postgres \
          --publish-all \
          --volume #{postgres_custom_source}:/docker-entrypoint-initdb.d \
          #{data_mount} \
          #{image_name}")
    fail 'Failed to create postgres container' unless result[:status].exitstatus == 0
    id = result[:stdout].chomp

    # this is necessary to add a wait for database creation
    wait_on_postgres_db(id, 'puppetdb')

    return id
  end

  def run_puppetdb_container
    # skip Postgres SSL initialization for tests with USE_PUPPETSERVER
    result = run_command("docker run --detach \
          --env USE_PUPPETSERVER=false \
          --env PUPPERWARE_ANALYTICS_ENABLED=false \
          --name puppetdb \
          --hostname puppetdb \
          --publish-all \
          --network #{@network} \
          #{@pdb_image}")
    fail 'Failed to create puppetdb container' unless result[:status].exitstatus == 0
    result[:stdout].chomp
  end

  def get_puppetdb_state
    pdb_uri = URI::join(get_container_port(@pdb_container, 8080), '/status/v1/services/puppetdb-status')
    response = Net::HTTP.get_response(pdb_uri)
    STDOUT.puts "retrieved raw puppetdb status: #{response.body}"
    case response
      when Net::HTTPSuccess then
        return JSON.parse(response.body)['state']
      else
        return ''
    end
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError => e
    STDOUT.puts "PDB not accepting connections yet #{pdb_uri}: #{e}"
    return ''
  rescue JSON::ParserError
    STDOUT.puts "Invalid JSON response: #{e}"
    return ''
  rescue
    STDOUT.puts "Failure querying #{pdb_uri}: #{$!}"
    raise
  end

  def get_postgres_extensions
    result = run_command("docker exec #{@postgres_container} psql --username=puppetdb --command=\"SELECT * FROM pg_extension\"")
    extensions = result[:stdout].chomp
    STDOUT.puts("retrieved extensions: #{extensions}")
    extensions
  end

  def wait_on_puppetdb_status(seconds = 240)
    # since pdb doesn't have a proper healthcheck yet, this could spin forever
    # add a timeout so it eventually returns.
    return retry_block_up_to_timeout(seconds) do
      get_puppetdb_state() == 'running' ? 'running' :
        raise('puppetdb never entered running state')
    end
  end

  before(:all) do
    @pdb_image = ENV['PUPPET_TEST_DOCKER_IMAGE']
    if @pdb_image.nil?
      error_message = <<-MSG
  * * * * *
  PUPPET_TEST_DOCKER_IMAGE environment variable must be set so we
  know which image to test against!
  * * * * *
      MSG
      fail error_message
    end

    @mapped_ports = {}

    # LCOW requires directories to exist
    create_host_volume_targets(ENV['VOLUME_ROOT'], VOLUMES)

    # Windows doesn't have the default 'bridge network driver
    network_opt = File::ALT_SEPARATOR.nil? ? '' : '--driver=nat'

    result = run_command("docker network create #{network_opt} puppetdb_test_network_#{Random.rand(1000)}")
    fail 'Failed to create network' unless result[:status].exitstatus == 0
    @network = result[:stdout].chomp

    @postgres_container = run_postgres_container

    @pdb_container = run_puppetdb_container
  end

  after(:all) do
    [
      @postgres_container,
      @pdb_container,
    ].each do |id|
      emit_log(id)
      STDOUT.puts("Killing container #{id}")
      run_command("docker container kill #{id}")
    end
    run_command("docker network rm #{@network}") unless @network.nil?
  end

  it 'should have started postgres' do
    expect(@postgres_container).to_not be_empty
  end

  it 'should have installed postgres extensions' do
    installed_extensions = get_postgres_extensions
    expect(installed_extensions).to match(/^\s+pg_trgm\s+/)
    expect(installed_extensions).to match(/^\s+pgcrypto\s+/)
  end

  it 'should have started puppetdb' do
    expect(@pdb_container).to_not be_empty
  end

  it 'should have a "running" puppetdb container' do
    expect(wait_on_puppetdb_status()).to eq('running')
  end
end
