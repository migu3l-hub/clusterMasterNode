#! /bin/bash

function install_xfsprogs(){
        echo "-->Instalando el paquete xfsprogs desde pacman..."
        pacman -Sy xfsprogs
        echo "-->Configurando el disco o particion ingresada..."
        mkfs.xfs -f -i size=2048 $1
        echo "-->Ingresando la particion en fstab.."
        echo $1 '/mnt/osd xfs rw,noatime,inode64 0 0' >> /etc/fstab
        echo "-->Creando carpetas en /mnt ..."
        existe_directorio "/mnt/osd"
        mkdir -p /mnt/osd && mount /mnt/osd
}

function existe_directorio(){
        if [ -d $1 ]; then
                echo -e "\e[31m Error el directorio ya existe: $1\e[0m";
        fi
}

function existe_archivo(){
        if [ -f $1 ]; then
                echo "-->El $1 existe";
        else
                echo -e "\e[31m ERROR no esta el archivo...\e[0m";
                exit 1;
        fi
}

function obtener_llaves_ceph(){
        echo "-->Obteniendo llaves ceph..."
        docker run -d --rm --net=host \
                --name ceph_mon \
                -v `pwd`/etc:/etc/ceph \
                -v `pwd`/var:/var/lib/ceph \
                -e NETWORK_AUTO_DETECT=4 \
                -e DEBUG=verbose \
                ceph/daemon:master-13b097c-mimic-centos-7-x86_64 mon

        docker exec -it ceph_mon ceph mon getmap -o /etc/ceph/ceph.monmap
        existe_archivo "var/bootstrap-osd/ceph.keyring"
        echo -e "\e[93m INFO: Deteniendo la imagen de ceph\e[0m";
        echo " "
        docker stop ceph_mon
}

function generando_llaves_swarm(){
        echo "-->Generando configuraciones swarm"
        docker config create ceph.conf etc/ceph.conf
        docker secret create ceph.monmap etc/ceph.monmap
        docker secret create ceph.client.admin.keyring etc/ceph.client.admin.keyring
        docker secret create ceph.mon.keyring etc/ceph.mon.keyring
        docker secret create ceph.bootstrap-osd.keyring var/bootstrap-osd/ceph.keyring
        echo "-->Mostrando configuraciones de swarm"
        docker config ls
        echo "-->Mostrando llaves de swarm"
        docker secret ls
        sleep 5
}

function desplegando_ceph_swarm(){
        docker stack deploy -c docker-compose.yml ceph
}

function comprobar_salud_ceph(){
        HEALTH='NULL'
        while [ $HEALTH != 'HEALTH_WARN' ]; do
                HEALTH=$(docker exec -i `docker ps -qf name=ceph_mon` ceph -s | grep "health" | awk -F: '{print $2}')
                echo "-->En espera..."
                sleep 15
        done
        echo "-->Ceph marca ok"
}

function comprobar_osd(){
        OSD='NULL'
        while [ $OSD != '1' ]; do
                OSD=$(docker exec -i `docker ps -qf name=ceph_mon` ceph -s | grep "osd:" | cut -d: -f 2 | cut -c 2)
                echo "-->En espera de los OSD"
                sleep 25
        done
        echo "-->OSD listos"
}

function configuracion_ceph(){
        echo "-->Configurando contenedor ceph..."
        docker exec -i `docker ps -qf name=ceph_mon` ceph osd pool create cephfs_data 64
        docker exec -i `docker ps -qf name=ceph_mon` ceph osd pool create cephfs_metadata 64
        docker exec -i `docker ps -qf name=ceph_mon` ceph fs new cephfs cephfs_metadata cephfs_data
        docker exec -i `docker ps -qf name=ceph_mon` ceph fs authorize cephfs client.swarm / rw | grep key | awk '{print $3}' > /root/.llave_ceph
        sleep 10
        sed 's/ //' /root/.llave_ceph > /root/.configsCluster/.ceph_key; rm /root/.llave_ceph
        docker exec -i `docker ps -qf name=ceph_mon` ceph osd pool set cephfs_data nodeep-scrub 1
}

function instalando_ceph(){
        pacman -Sy ceph
        archivo='/root/.configsCluster/ips_cluster'
        CONTADOR=0
        while read linea ; do
                ip add | grep -wom 1 ${linea}
                if [ $(echo $?) != "0" ]; then
                        array[$CONTADOR]=${linea}
                fi
                let CONTADOR=CONTADOR+1
        done <<< "`cat $archivo`"
        echo ${array[@]} ":/ /mnt/ceph ceph _netdev,name=swarm,secretfile=/root/.configsCluster/.ceph_key 0 0" >> /etc/fstab
}

function crear_carpeta_ceph(){
        existe_directorio "/mnt/ceph"
        mkdir /mnt/ceph
}

function configuracion_archivo_ceph(){
        archivo='/root/.configsCluster/ips_cluster'
        CONTADOR=0
        while read linea ; do
                array[$CONTADOR]=${linea}
                let CONTADOR=CONTADOR+1
        done <<< "`cat $archivo`"
        cadena="mon host = ${array[@]}"
        sed -i "s/mon host = $1/$cadena/" etc/ceph.conf
}

function configuracion_hostname_ceph(){
        archivo='/root/.configsCluster/hostname_cluster'
        CONTADOR=0
        while read linea ; do
                array[$CONTADOR]=${linea}
                let CONTADOR=CONTADOR+1
        done <<< "`cat $archivo`"
        texto="mon initial members = ${array[@]}"
        sed -i "s/mon initial members = ${array[0]}/$texto/" etc/ceph.conf
        echo 'mon cluster log file = /var/lib/ceph/mon/$cluster-$id/$channel.log' >> etc/ceph.conf
}

function main(){
        install_xfsprogs $2
        obtener_llaves_ceph
        echo -e "\e[93m INFO: Se configurara el archivo ceph.conf de manera automatica \e[0m";
        configuracion_archivo_ceph $1
        configuracion_hostname_ceph
        generando_llaves_swarm
        sleep 2
        desplegando_ceph_swarm
        sleep 30
        echo "-->Comprobando salud de ceph"
        sleep 60
        #comprobar_salud_ceph
        #comprobar_osd
        configuracion_ceph
        instalando_ceph
        crear_carpeta_ceph
        echo "-->listo"
}

main $1 $2