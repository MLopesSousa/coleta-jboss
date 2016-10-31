#!/bin/bash

IP="172.30.121.73"
PORT=9999
CMD="/usr/jboss/jboss-eap-6.1/bin/jboss-cli.sh --connect --controller=${IP}:${PORT}"
DATA_DIR=/tmp/moni
DBDIR=$DATA_DIR/db
LOG_FILE=$DATA_DIR/moni.log
TIMESTAMP="date +%Y-%m-%dT%H:%M:%S-0300"
ENVIRONMENT="PRODUCAO-INTRANET"
APP_SERVER="jboss-eap-6.1"
OPT=$1

HOSTSFILE=$DATA_DIR/hosts.txt
SERVERSFILE=$DATA_DIR/servers.txt
SERVERGROUPSFILE=$DATA_DIR/servergroups.txt
APPLICATIONSFILE=$DATA_DIR/applications.txt
THREADPOOLSFILE=$DATA_DIR/threadpools.txt
DATASOURCESFILE=$DATA_DIR/datasources.txt
JVMMETRICFILE=$DATA_DIR/jvm.txt
DATASOURCEMETRICFILE=$DATA_DIR/datasource.txt
HTTPMETRICFILE=$DATA_DIR/http.txt
TIMMERMETRICFILE=$DATA_DIR/timmer.txt
THREADFILE=$DATA_DIR/thread.txt

SCRIPTNAME=`basename $0`
PIDFILE=/tmp/${SCRIPTNAME}.pid
PIDFILECOUNT=$DATA_DIR/pidfilecount.txt

touch ${PIDFILECOUNT}

if [ -f ${PIDFILE} ]; then
   OLDPID=`cat ${PIDFILE}`
   RESULT=`ps -ef | grep ${OLDPID} | grep ${SCRIPTNAME}`

   if [ $(wc -l ${PIDFILECOUNT} |awk '{print $1}') -gt 6 ]; then
        rm -f ${PIDFILECOUNT}
        if [ -f ${PIDFILE} ]; then
                kill -9 $(cat ${PIDFILE})
                rm ${PIDFILE}
        fi
   fi

   if [ -n "${RESULT}" ]; then
     echo "Script already running! Exiting"
     echo 1 >> ${PIDFILECOUNT}
     exit 255
   fi

fi

PID=`ps -ef | grep ${SCRIPTNAME} | head -n1 |  awk ' {print $2;} '`
echo ${PID} > ${PIDFILE}

if [ ! -e ${DATA_DIR} ]; then
        mkdir -p $DATA_DIR
        mkdir -p $DBDIR

fi

######################################################################
# definicao das funcoes
######################################################################

function testTmpFile() {
        TMP_FILE=$1
        END_FILE=$2

        if [ $(grep '"outcome" => "failed"' $TMP_FILE 2> /dev/null |wc -l) -eq 0 ]; then
                grep -v "master" $TMP_FILE > $END_FILE && rm -rf $TMP_FILE
        fi
}

function removeFromCommand() {
        FILE=$1
        STR=$2
        grep -v $STR $FILE > /tmp/$$.removeFromCommand && mv /tmp/$$.removeFromCommand $FILE
}

function buildHostListFunction() {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt

        echo "$(eval $TIMESTAMP) :: buildBase :: buildHostListFunction"
        $CMD "ls /host=" > $TMP_FILE && testTmpFile $TMP_FILE $HOSTSFILE
}

function buildInstanceListFunction() {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt

        for host in $(cat $HOSTSFILE 2> /dev/null); do
                for instance in $($CMD "ls /host=$host/server"); do
                        echo "$(eval $TIMESTAMP) :: buildBase :: buildInstanceListFunction :: $host - $instance"
                        echo "$host:$instance" >> $TMP_FILE
                done
        done

        testTmpFile $TMP_FILE $SERVERSFILE
}

function buildServerGroupListFunction() {
        arrFile=("");
        count=0;
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        echo "" > $DATA_DIR/command.txt

        for line in $(cat $SERVERSFILE 2> /dev/null)
        do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                file_tmp="$DATA_DIR/buildServerGroupList:$host:$instance" && arrFile[$count]="$file_tmp"
                echo "/host=$host/server-config=$instance:read-resource(recursive=true) > $file_tmp" >> $DATA_DIR/command.txt
                count=$(($count + 1))

        done

        $CMD --file=$DATA_DIR/command.txt

        for file in $(echo ${arrFile[@]})
        do
                serverGroup=$(grep \"group\" $file |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                port=$(grep \"socket-binding-port-offset\" $file |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                instance=$(echo $file |awk -F':' '{print $3}')
                host=$(echo $file |awk -F':' '{print $2}')
                index=$(echo $file |awk -F':' '{print $4}')
                profile=$($CMD "/server-group=$serverGroup:read-resource" |grep '"profile" =>' |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')

                if [[ $(grep '"outcome" => "failed"' $file |wc -l) -gt 0  || ! -f $file ]]; then
                        echo "$(eval $TIMESTAMP) :: buildBase :: buildServerGroupListFunction :: ERROR :: $host - $instance - $profile - $serverGroup"

                        removeFromCommand "$DATA_DIR/command.txt" $file
                        $CMD --file=$DATA_DIR/command.txt

                else
                        echo "$(eval $TIMESTAMP) :: buildBase :: buildServerGroupListFunction :: $host - $instance - $profile - $serverGroup"
                        echo "$host:$instance:$serverGroup:$port:$profile" >> $TMP_FILE
                fi

        done

        testTmpFile $TMP_FILE $SERVERGROUPSFILE

}

function buildApplicationListFunction {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        HAS="XXXXXXXXXXXXX"

        servergroups=$(awk -F':' '{print $3}' $SERVERGROUPSFILE |sort |uniq)
        for servergroup in $servergroups; do
                for application in $($CMD "ls /server-group=$servergroup/deployment"); do
                        for host in $(grep ":$servergroup:" $SERVERGROUPSFILE |awk -F':' '{print $1}' |sort |uniq); do
                                for server in $(grep "$host:" $SERVERGROUPSFILE |grep ":$servergroup:" |awk -F':' '{print $2}' |sort |uniq); do
                                        echo "$host:$server:$application:" >> $DATA_DIR/moni_tmp.txt
                                done
                        done
                done
        done

        for application in $(awk -F':' '{print $3}' $DATA_DIR/moni_tmp.txt |sort |uniq); do
                f=""
                host=$(grep ":$application:" $DATA_DIR/moni_tmp.txt |head -1 |awk -F':' '{print $1}')
                server=$(grep ":$application:" $DATA_DIR/moni_tmp.txt |head -1 |awk -F':' '{print $2}')
                context=$($CMD "/host=$host/server=$server/deployment=$application:read-resource(recursive=true)" |grep 'context-root' |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g' |tr -d '\n')

                for c in $context; do f=${f}${c}; done
                sed -i 's#'$application':#'$application':'$f':'$HAS'#g' $DATA_DIR/moni_tmp.txt
                echo "$(eval $TIMESTAMP) :: buildBase :: buildApplicationListFunction :: $host - $server - $application - $context"
        done

        testTmpFile $TMP_FILE $APPLICATIONSFILE
}

function buildBoundedQueueThreadPoolListFunction {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt

        profiles=$(awk -F':' '{print $5}' $SERVERGROUPSFILE |sort |uniq)
        for profile in $profiles; do
                for pool in $($CMD "ls /profile=$profile/subsystem=threads/unbounded-queue-thread-pool="); do
                        for linha in $(grep ":$profile$" $SERVERGROUPSFILE |sort |uniq); do
                                host=$(echo $linha |awk -F':' '{print $1}')
                                instance=$(echo $linha |awk -F':' '{print $2}')

                                echo "$(eval $TIMESTAMP) :: buildBase :: buildUnboundedQueueThreadPoolListFunction :: $host - $instance - $pool"
                                echo "$host:$instance:$pool:unbounded-queue-thread-pool" >> $TMP_FILE
                        done
                done

                for pool in $($CMD "ls /profile=$profile/subsystem=threads/bounded-queue-thread-pool="); do
                        for linha in $(grep ":$profile$" $SERVERGROUPSFILE |sort |uniq); do
                                host=$(echo $linha |awk -F':' '{print $1}')
                                instance=$(echo $linha |awk -F':' '{print $2}')

                                echo "$(eval $TIMESTAMP) :: buildBase :: buildBoundedQueueThreadPoolListFunction :: $host - $instance - $pool"
                                echo "$host:$instance:$pool:bounded-queue-thread-pool" >> $TMP_FILE
                        done
                done
        done

        testTmpFile $TMP_FILE $THREADPOOLSFILE
}

function buildDatasourceListFunction {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt

        profiles=$(awk -F':' '{print $5}' $SERVERGROUPSFILE |sort |uniq)
        for profile in $profiles; do
                for pool in $($CMD "ls /profile=$profile/subsystem=datasources/data-source="); do
                        jndi=$($CMD "/profile=$profile/subsystem=datasources/data-source=$pool:read-resource" |grep 'jndi-name' |awk -F'=>' '{print $2}' |sed 's/,//g' |tr -d '[ ]' |sed 's/"//g')
                        for host in $(grep ":$profile" $SERVERGROUPSFILE |awk -F':' '{print $1}' |sort |uniq); do
                                for instance in $(grep ":$profile" $SERVERGROUPSFILE |grep "$host:" |awk -F':' '{print $2}' |sort |uniq); do
                                        echo "$(eval $TIMESTAMP) :: buildBase :: buildDatasourceListFunction :: $host - $instance - $pool - $jndi"
                                        echo "$host:$instance:$pool:data-source:$jndi" >> $TMP_FILE
                                done
                        done
                done

                for pool in $($CMD "ls /profile=$profile/subsystem=datasources/xa-data-source="); do
                        jndi=$($CMD "/profile=$profile/subsystem=datasources/xa-data-source=$pool:read-resource" |grep 'jndi-name' |awk -F'=>' '{print $2}' |sed 's/,//g' |tr -d '[ ]' |sed 's/"//g')
                        for host in $(grep ":$profile" $SERVERGROUPSFILE |awk -F':' '{print $1}' |sort |uniq); do
                                for instance in $(grep ":$profile" $SERVERGROUPSFILE |grep "$host:" |awk -F':' '{print $2}' |sort |uniq); do
                                        echo "$(eval $TIMESTAMP) :: buildBase :: buildDatasourceListFunction :: $host - $instance - $pool - $jndi"
                                        echo "$host:$instance:$pool:xa-data-source:$jndi" >> $TMP_FILE
                                done
                        done
                done
        done

        testTmpFile $TMP_FILE $DATASOURCESFILE
}

function getServerGroupListFunction() {
         for line in $(cat $SERVERGROUPSFILE)
         do
                HOST=$(echo $line |awk -F':' '{print $1}')
                TARGET=$(echo $line |awk -F':' '{print $3}')
                INSTANCE=$(echo $line |awk -F':' '{print $2}')
                PORT=$(echo $line |awk -F':' '{print $4}')
                PROFILE=$(echo $line |awk -F':' '{print $5}')

                echo "$(eval $TIMESTAMP) INSTANCE $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $PORT $PROFILE"
        done
}

function getApplicationListFunction() {
        for line in $(cat $APPLICATIONSFILE)
        do
                HOST=$(echo $line |awk -F':' '{print $1}')
                INSTANCE=$(echo $line |awk -F':' '{print $2}')
                APP=$(echo $line |awk -F':' '{print $3}')
                TARGET=$(grep "$HOST:$INSTANCE:" $SERVERGROUPSFILE |awk -F':' '{print $3}' |sort |uniq)
                CONTEXT=$(echo $line |awk -F':' '{print $4}')
                HAS=$(echo $line |awk -F':' '{print $5}')
                echo "$(eval $TIMESTAMP) APPLICATION $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APP ${CONTEXT:-/none} ${HAS}"
        done

}

function buildDeployDiffFunction {
        echo " " > $DATA_DIR/command.txt;

        for application in $(cat $APPLICATIONSFILE); do
                host=$(echo $application |awk -F':' '{print $1}')
                instance=$(echo $application |awk -F':' '{print $2}')
                app=$(echo $application |awk -F':' '{print $3}')
                file_tmp="$DATA_DIR/DDF_:$host:$instance:$app"
                echo "/host=$host/server=$instance/deployment=$app:read-resource > $file_tmp" >> $DATA_DIR/command.txt
        done

        $CMD --file=$DATA_DIR/command.txt;

        function main {
                for file in $(ls $DATA_DIR/ |grep 'DDF_'); do
                        HOST=$(echo $file |awk -F':' '{print $2}')
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        APP=$(echo $file |awk -F':' '{print $4}')
                        TARGET=$(grep "$HOST:$INSTANCE:" $SERVERGROUPSFILE |awk -F':' '{print $3}')
                        HAS=$(cat ${DATA_DIR}/${file} |fgrep '"content" => [{' -A 5 |fgrep -B 5 '}}]' |egrep -v '(\{|\})' |sed 's/,//g; s/0x//g' |tr -d '[ ]' |tr -d '\n')
                        OLDFILE=${DBDIR}/${file}.hist

                        if [ $HAS != "" ]; then
                                if [ -s ${OLDFILE} ]; then
                                        if [ $(cat $OLDFILE) != $HAS ]; then
                                                echo $HAS > $OLDFILE && echo "$(eval $TIMESTAMP) DEPLOY $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APP $HAS"
                                        fi
                                else
                                        echo $HAS > $OLDFILE && echo "$(eval $TIMESTAMP) DEPLOY $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APP $HAS"
                                fi
                        fi
                        removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}
                done
        }

        main
}

function buildJVMMemoryMetricsFunction {
        echo "" > $DATA_DIR/command.txt
        echo "" > $JVMMETRICFILE

        for line in $(cat $SERVERSFILE); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                file_tmp="$DATA_DIR/buildJVMM_:$host:$instance"
                echo "/host=$host/server=$instance/core-service=platform-mbean/type=memory:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt
        done

        $CMD --file=$DATA_DIR/command.txt

        function main {
                for file in $(ls $DATA_DIR/ |grep 'buildJVMM_'); do
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        HOST=$(echo $file |awk -F':' '{print $2}')

                        if [[ $(grep -i 'Failed' ${DATA_DIR}/${file} |wc -l) -gt 0 || ! -f ${DATA_DIR}/$file ]]; then
                                echo "Error - ${DATA_DIR}/${file}"
                                removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}

                                $CMD --file=$DATA_DIR/command.txt
                                main
                        else
                                HEAP_MAX=$(grep -w "\"heap-memory-usage\"" -A 5 ${DATA_DIR}/$file |grep max |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g' |sed 's/L//g')
                                HEAP_USED=$(grep -w "\"heap-memory-usage\"" -A 5 ${DATA_DIR}/$file |grep used |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g'|sed 's/L//g')
                                PERMGEN_MAX=$(grep -w "\"non-heap-memory-usage\"" -A 5 ${DATA_DIR}/$file |grep max |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g' |sed 's/L//g')
                                PERMGEN_USED=$(grep -w "\"non-heap-memory-usage\"" -A 5 ${DATA_DIR}/$file |grep used |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g'|sed 's/L//g')
                                TARGET=$(grep "$HOST:$INSTANCE:" $SERVERGROUPSFILE |awk -F':' '{print $3}')

                                echo "$(eval $TIMESTAMP) JVMMEMORIA $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $HEAP_MAX $HEAP_USED $PERMGEN_MAX $PERMGEN_USED" >> $JVMMETRICFILE
                                removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}
                        fi
                done
        }

        main
        cat $JVMMETRICFILE

}

function buildBoundedQueueThreadPoolMetricsFunction {
        arrFile=("");
        echo "" > $DATA_DIR/command.txt;
        echo "" > $THREADFILE

        for line in $(cat $THREADPOOLSFILE); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                pool=$(echo $line |awk -F':' '{print $3}')
                tipo=$(echo $line |awk -F':' '{print $4}')
                file_tmp="$DATA_DIR/buildTH_:$host:$instance:$pool"
                echo "/host=$host/server=$instance/subsystem=threads/$tipo=$pool:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt;
        done

        $CMD --file=$DATA_DIR/command.txt

        function main {
                for file in $(ls $DATA_DIR/ |grep 'buildTH_'); do
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        HOST=$(echo $file |awk -F':' '{print $2}')
                        POOL=$(echo $file |awk -F':' '{print $4}')

                        if [[ $(grep -i 'Failed' ${DATA_DIR}/${file} |wc -l) -gt 0 || ! -f ${DATA_DIR}/$file ]]; then
                                echo "Error - ${DATA_DIR}/${file}"
                                removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}

                                $CMD --file=$DATA_DIR/command.txt
                                main
                        else
                                QUEUE_MAX=$(grep -w queue-length ${DATA_DIR}/$file  |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                                QUEUE_SIZE=$(grep -w queue-size ${DATA_DIR}/$file |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')

                                echo "$(eval $TIMESTAMP) HTTPTHREAD $ENVIRONMENT $HOST $APP_SERVER $INSTANCE $POOL $QUEUE_MAX $QUEUE_SIZE" >> $THREADFILE
                                removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}
                        fi
                done
        }

        main
        cat $THREADFILE
}

function buildDatasourceMetricsFunction {
        arrFile=("");
        echo " " > $DATA_DIR/command.txt;
        echo "" > $DATASOURCEMETRICFILE

        for line in $(cat $DATASOURCESFILE); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                pool=$(echo $line |awk -F':' '{print $3}')
                datasourceKind=$(echo $line |awk -F':' '{print $4}')
                file_tmp="$DATA_DIR/buildDM_:$host:$instance:$datasourceKind:$pool"

                echo "/host=$host/server=$instance/subsystem=datasources/$datasourceKind=$pool/statistics=pool:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt;
        done

        $CMD --file=$DATA_DIR/command.txt

        function main {
                for file in $(ls $DATA_DIR/ |grep 'buildDM_'); do
                        if  [ -f ${DATA_DIR}/$file ]; then
                                INSTANCE=$(echo $file |awk -F':' '{print $3}')
                                HOST=$(echo $file |awk -F':' '{print $2}')

                                if [ $(grep -i 'Failed' ${DATA_DIR}/${file} |wc -l) -gt 0 ]; then
                                        echo "Error - ${DATA_DIR}/${file}"
                                        removeFromCommand "$DATA_DIR/command.txt" "buildDM_:${HOST}:${INSTANCE}:"

                                        $CMD --file=$DATA_DIR/command.txt
                                        for i in $(ls $DATA_DIR |grep "buildDM_" |grep ":${HOST}:" |grep "${INSTANCE}"); do rm -rf ${DATA_DIR}/${i}; done
                                        main
                                else
                                        POOL_USED=$(grep -w InUseCount ${DATA_DIR}/$file  |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                                        POOL_FREE=$(grep -w AvailableCount ${DATA_DIR}/$file |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                                        if [[ $POOL_USED -eq $POOL_USED && $POOL_FREE -eq $POOL_FREE ]]; then POOL_MAX=$(($POOL_USED + $POOL_FREE)); else POOL_MAX=0; fi
                                        POOL=$(echo $file |awk -F':' '{print $5}')
                                        TARGET=$(grep "$HOST:$INSTANCE:" $SERVERGROUPSFILE |awk -F':' '{print $3}')
                                        JNDI=$(grep "$HOST:$INSTANCE:$POOL:" $DATASOURCESFILE |sort |uniq |awk -F'data-source:' '{print $2}')
                                        echo "$(eval $TIMESTAMP) DATASOURCE $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $POOL $POOL_MAX $POOL_USED $POOL_FREE \"$JNDI\"" >> $DATASOURCEMETRICFILE
                                        removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}
                                fi
                        fi
                done
        }

        main
        cat $DATASOURCEMETRICFILE

}

function buildHttpMetricsFunction() {
        arrFile=("");
        echo "" > $DATA_DIR/command.txt
        echo "" > $HTTPMETRICFILE

        for line in $(cat $APPLICATIONSFILE); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                application=$(echo $line |awk -F':' '{print $3}')
                context=$(echo $line |awk -F':' '{print $4}' |sed 's#/##g')

                if [ $context ]; then
                        file_tmp="$DATA_DIR/buildHM_:$host:$instance:$application"
                        echo "/host=$host/server=$instance/deployment=$application/subsystem=web:read-attribute(name=active-sessions) > $file_tmp" >> $DATA_DIR/command.txt;
                fi
        done

        $CMD --file=$DATA_DIR/command.txt

        function main {
                for file in $(ls $DATA_DIR/ |grep 'buildHM_'); do
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        HOST=$(echo $file |awk -F':' '{print $2}')

                        if [[ $(grep -i 'Failed' ${DATA_DIR}/${file} 2> /dev/null |wc -l) -gt 0 || ! -f ${DATA_DIR}/$file ]]; then
                                echo "Error - ${DATA_DIR}/${file}"
                                removeFromCommand "$DATA_DIR/command.txt" "$HOST:$INSTANCE" && rm -rf ${DATA_DIR}/${file}
                                $CMD --file=$DATA_DIR/command.txt
                                main
                        else
                                return=$(grep -w result ${DATA_DIR}/${file} 2> /dev/null |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                                CONNECTION=0
                                if [[ $return =~ "^[0-9]+$" ]]; then CONNECTION=$return; fi
                                APPLICATION=$(echo ${file} |awk -F':' '{print $4}')
                                TARGET=$(grep "$HOST:$INSTANCE:" $SERVERGROUPSFILE |awk -F':' '{print $3}')
                                echo "$(eval $TIMESTAMP) HTTPSESSION $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APPLICATION $CONNECTION" >> $HTTPMETRICFILE
                                removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}
                        fi

                done
        }

        main
        cat $HTTPMETRICFILE
}

function buildTimmerListFunction() {
        arrFile=("");
        echo "" > $DATA_DIR/command.txt
        echo "" > $TIMMERMETRICFILE

        for line in $(cat $APPLICATIONSFILE); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                application=$(echo $line |awk -F':' '{print $3}')

                for ejb in $($CMD "ls /host=$host/server=$instance/deployment=$application/subsystem=ejb3/singleton-bean"); do
                        file_tmp="$DATA_DIR/buildTM_:$host:$instance:$application:$ejb"
                        echo "/host=$host/server=$instance/deployment=$application/subsystem=ejb3/singleton-bean=$ejb:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt;
                done
        done

        $CMD --file=$DATA_DIR/command.txt

        function main {
                for file in $(ls $DATA_DIR/ |grep 'buildTM_'); do
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        HOST=$(echo $file |awk -F':' '{print $2}')

                        if [[ $(grep -i 'Failed' ${DATA_DIR}/${file} 2> /dev/null |wc -l) -gt 0 || ! -f ${DATA_DIR}/$file ]]; then
                                echo "Error - ${DATA_DIR}/${file}"
                                removeFromCommand "$DATA_DIR/command.txt" "$HOST:$INSTANCE" && rm -rf ${DATA_DIR}/${file}
                                $CMD --file=$DATA_DIR/command.txt
                                main
                        else
                                APPLICATION=$(echo ${file} |awk -F':' '{print $4}')
                                EJB=$(echo ${file} |awk -F':' '{print $5}')
                                TARGET=$(grep "$HOST:$INSTANCE:" $SERVERGROUPSFILE |awk -F':' '{print $3}')

                                if [ $(fgrep '"timers" => []' ${DATA_DIR}/${file} 2> /dev/null |wc -l) -le 0 ]; then
                                        C=$(grep '"year"' ${DATA_DIR}/${file} 2> /dev/null |wc -l)
                                        for timmer in $(seq $C); do
                                                YEAR=$(grep '"year"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')
                                                MONTH=$(grep '"month"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')
                                                DAYOFMONTH=$(grep '"day-of-month"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')
                                                DAYOFWEEK=$(grep '"day-of-week"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')
                                                HOUR=$(grep '"hour"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')
                                                MINUTE=$(grep '"minute"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')
                                                SECOND=$(grep '"second"' ${DATA_DIR}/${file} 2> /dev/null | sed $timmer'q;d' |awk -F'=>' '{print $NF}' |sed 's/"//g' |sed 's/",//g' |sed 's/ //g')

                                                echo "$(eval $TIMESTAMP) EJBTIMMER $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APPLICATION $EJB \"$YEAR\" \"$MONTH\" \"$DAYOFMONTH\" \"$DAYOFWEEK\" \"$HOUR\" \"$MINUTE\" \"$SECOND\"" >> $TIMMERMETRICFILE
                                                C=$(($C + 1))
                                        done

                                        removeFromCommand "$DATA_DIR/command.txt" $file && rm -rf ${DATA_DIR}/${file}
                                fi
                        fi

                done
        }

        main
        cat $TIMMERMETRICFILE
}

######################################################################
# switch
######################################################################

case $OPT in
        buildHostList)
                buildHostListFunction
        ;;

        buildInstanceList)
                buildInstanceListFunction
        ;;

        buildServerGroupList)
                buildServerGroupListFunction
        ;;

        buildApplicationList)
                buildApplicationListFunction
        ;;

        buildDatasourceList)
                buildDatasourceListFunction
        ;;

        buildJVMMemoryMetrics)
                buildJVMMemoryMetricsFunction
        ;;

        buildDatasourceMetrics)
                buildDatasourceMetricsFunction
        ;;

        buildHttpMetrics)
                buildHttpMetricsFunction
        ;;

        getApplicationList)
                getApplicationListFunction
        ;;

        getServerGroupList)
                getServerGroupListFunction
        ;;

        buildBase)
                echo "$(eval $TIMESTAMP) :: buildHostListFunction"
                buildHostListFunction

                echo "$(eval $TIMESTAMP) :: buildInstanceListFunction"
                buildInstanceListFunction

                echo "$(eval $TIMESTAMP) :: buildServerGroupListFunction"
                buildServerGroupListFunction

                echo "$(eval $TIMESTAMP) :: buildBoundedQueueThreadPoolListFunction"
                buildBoundedQueueThreadPoolListFunction

                echo "$(eval $TIMESTAMP) :: buildApplicationListFunction"
                buildApplicationListFunction

                echo "$(eval $TIMESTAMP) :: buildDatasourceListFunction"
                buildDatasourceListFunction
        ;;

        buildMetrics)
                getServerGroupListFunction
                getApplicationListFunction
                buildTimmerListFunction
                buildJVMMemoryMetricsFunction
                buildDatasourceMetricsFunction
                buildHttpMetricsFunction
                buildBoundedQueueThreadPoolMetricsFunction
                buildDeployDiffFunction

        ;;
esac

if [ -f ${PIDFILE} ]; then
    rm ${PIDFILE}
fi
