## Dockerfiles
### base

- devops-ubuntu<b style='color:red'>b</b>-18.04: for ubuntu 18.04 <b style='color:red'>b</b>asic
- devops-ubuntu<b style='color:red'>d</b>-18.04: for ubuntu 18.04 <b style='color:red'>d</b>ocker in docker

### java

## Build container
```sh
$ docker build -t <your_container_name> -f <your_dockerfile> <path>
```
E.g.:
```sh
$ docker build -t marslo-ubuntu-basic:18.04 -f base/devops-ubuntub base/
$ docker tag marslo-ubuntu-basic:18.04 my.company.com:443/devops/ubuntu-basic:18.04
$ docker login -u <my_account> my.artifactory.company.com:443
$ docker push my.artifactory.company.com:443/devops/ubuntu-basic:18.04
```
## Use docker in docker
### On ubuntu
```sh
$ docker pull my.artifactory.company.com/devops/ubuntu-basic:18.04
$ docker run --name marslo-dockerindocker -d \
  --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -it \
  my.artifactory.company.com/devops/ubuntu-basic:18.04
$ docker exec -it marslo-dockerindocker bash                            # for devops account
$ docker exec -it -u 0 marslo-dockerindocker bash                       # for root account
```
### On Mac
