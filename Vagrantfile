Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vbguest.auto_update = false

  # Load Balancer
  config.vm.define "lb" do |lb|
    lb.vm.hostname = "lb"
    lb.vm.network "private_network", ip: "192.168.56.10"
    lb.vm.provider "virtualbox" do |vb|
      vb.memory = "512"
      vb.cpus = 1
    end
    lb.vm.provision "shell", path: "provision/provision-lb.sh"
  end

  # Redis Centralisé
  config.vm.define "redis" do |redis|
    redis.vm.hostname = "redis"
    redis.vm.network "private_network", ip: "192.168.56.20"
    redis.vm.provider "virtualbox" do |vb|
      vb.memory = "512"
      vb.cpus = 1
    end
    redis.vm.provision "shell", path: "provision/provision-redis.sh"
  end

  # Web nodes
  (1..3).each do |i|
    config.vm.define "web#{i}" do |web|
      web.vm.hostname = "web#{i}"
      web.vm.network "private_network", ip: "192.168.56.#{10+i}"
      web.vm.provider "virtualbox" do |vb|
        vb.memory = "512"
        vb.cpus = 1
      end
      web.vm.provision "shell", path: "provision/provision-web.sh"
    end
  end
end
