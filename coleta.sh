#!/bin/bash

######################################################################
# definicao das variaveis
######################################################################

CMD="/usr/jboss/jboss-eap-6.3/bin/jboss-cli.sh --connect --controller=127.0.0.1:9999"
DATA_DIR=/tmp/coleta
LOG_FILE=$DATA_DIR/moni.log
TIMESTAMP="date +%Y-%m-%dT%H:%M:%S-0300"
ENVIRONMENT="INTRANET"
APP_SERVER="jboss-eap-6.1"

OPT=$1

######################################################################
# rotinas de controle
######################################################################

SCRIPTNAME=`basename $0`
PIDFILE=/tmp/${SCRIPTNAME}.pid
PIDFILECOUNT=$DATA_DIR/pidfilecount.txt
touch ${PIDFILECOUNT}

if [ -f ${PIDFILE} ]; then
   OLDPID=`cat ${PIDFILE}`
   RESULT=`ps -ef | grep ${OLDPID} | grep ${SCRIPTNAME}`

   if [ $(wc -l ${PIDFILECOUNT} |awk '{print $1}') -gt 30 ]; then
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

fi

######################################################################
# definicao das funcoes
######################################################################

function testTmpFile() {
        TMP_FILE=$1
        END_FILE=$2

        #if [[ $(grep '"outcome" => "failed"' $TMP_FILE 2> /dev/null) -gt 0 || $(grep 'sd2' $TMP_FILE 2> /dev/null) -eq 0 || test -f $TMP_FILE ]]; then
        if [[ -f $TMP_FILE || $(grep '"outcome" => "failed"' $TMP_FILE 2> /dev/null |wc -l) -eq 0 || $(grep 'sd2' $TMP_FILE 2> /dev/null) -gt 0 ]]; then
                grep -v "master" $TMP_FILE > $END_FILE && rm -rf $TMP_FILE

        fi
        
}

function removeFromCommand() {
        FILE=$1
        STR=$2
        grep -v $STR $FILE > /tmp/$$.removeFromCommand && mv /tmp/$$.removeFromCommand $FILE

}

# gerar lista dos hosts
# registrados no domain

function buildHostListFunction() {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        END_FILE=$DATA_DIR/hosts.txt
        $CMD "ls /host=" > $TMP_FILE && testTmpFile $TMP_FILE $END_FILE

}

# gerar lista dos server
# baseado na lista de hosts

function buildInstanceListFunction() {

        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        END_FILE=$DATA_DIR/server.txt

        for host in $(cat $DATA_DIR/hosts.txt 2> /dev/null); do
                for instance in $($CMD "ls /host=$host/server"); do
                        echo "$host:$instance" >> $TMP_FILE

                done

        done
        
        testTmpFile $TMP_FILE $END_FILE

}

# gerar lista do server groups
# baseada nos pares host:instance

function buildServerGroupListFunction() {
        arrFile=(""); count=0;
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        END_FILE=$DATA_DIR/server_group.txt
        echo " " > $DATA_DIR/command.txt

        # com o objetivo de executas esta tarefa com o minimo
        # possivel de iteracoes com a API do Jboss, todos os
        # comando serao executados dentro de um batch que
        # redirecionara o output de cada linha para um arquivo
        # que sera nomaeado com o seguinte formato:
        # buildServerGroupList:$host:$instance

        for line in $(cat $DATA_DIR/server.txt 2> /dev/null)
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

                # caso a execucao do comando tenha resultado em erro
                # o comando sera removido do arquivo de batch "server_group_command.txt"
                # e esse sera executado novamente

                if [[ $(grep '"outcome" => "failed"' $file |wc -l) -gt 0  || ! -f $file ]]; then
                        echo "Error! $host:$instance"
                        echo "Removendo $file do command.txt"
                        echo "Executando novo command.txt"
                        
                        removeFromCommand "command.txt" $file
                        $CMD --file=$DATA_DIR/command.txt

                else
                        echo "$host:$instance:$serverGroup:$port" >> $TMP_FILE

                fi

        done

        testTmpFile $TMP_FILE $END_FILE

}

# gerar lista de aplicacoes
# baseada nos pares host:instance

function buildApplicationListFunction {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        END_FILE=$DATA_DIR/application.txt

        for line in $(cat $DATA_DIR/server.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')

                for application in $($CMD "ls /host=$host/server=$instance/deployment"); do
                        echo "$host:$instance:$application" >> $TMP_FILE

                done

        done

        testTmpFile $TMP_FILE $END_FILE

}

# gerar lista de BoundedQueueThreadPool
# baseada nos pares host:instance

function buildBoundedQueueThreadPoolListFunction {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        END_FILE=$DATA_DIR/bounded_queue_thread_pool.txt

        for line in $(cat $DATA_DIR/server.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')

                for pool in $($CMD "ls /host=$host/server=$instance/subsystem=threads/bounded-queue-thread-pool"); do
                        echo "$host:$instance:$pool" >> $TMP_FILE

                done

        done

        testTmpFile $TMP_FILE $END_FILE

}

# gerar lista de datasources
# baseada nos pares host:instance

function buildDatasourceListFunction {
        TMP_FILE=$DATA_DIR/moni_tmp.txt && echo "" > $DATA_DIR/moni_tmp.txt
        END_FILE=$DATA_DIR/datasource.txt

        for line in $(cat $DATA_DIR/server.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')

                for datasource in $($CMD "ls /host=$host/server=$instance/subsystem=datasources/data-source"); do
                        echo "$host:$instance:$datasource:data-source" >> $TMP_FILE

                done

                for datasource in $($CMD "ls /host=$host/server=$instance/subsystem=datasources/xa-data-source"); do
                        echo "$host:$instance:$datasource:xa-data-source" >> $TMP_FILE

                done

        done

        testTmpFile $TMP_FILE $END_FILE

}

######################################################################
# definicao das funcoes de listar
######################################################################

function getServerGroupListFunction() {
         for line in $(cat $DATA_DIR/server_group.txt)
         do
                HOST=$(echo $line |awk -F':' '{print $1}')
                TARGET=$(echo $line |awk -F':' '{print $3}')
                INSTANCE=$(echo $line |awk -F':' '{print $2}')
                PORT=$(echo $line |awk -F':' '{print $4}')

                echo "$(eval $TIMESTAMP) INSTANCE $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $PORT"

        done

}

function getApplicationListFunction() {
        for line in $(cat $DATA_DIR/application.txt)
        do
                HOST=$(echo $line |awk -F':' '{print $1}')
                INSTANCE=$(echo $line |awk -F':' '{print $2}')
                APP=$(echo $line |awk -F':' '{print $3}')
                TARGET=$(grep "$HOST:$INSTANCE:" $DATA_DIR/server_group.txt |awk -F':' '{print $3}')
                echo "$(eval $TIMESTAMP) APPLICATION $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APP"

        done

}


######################################################################
# definiao das funcoes de coleta de metricas
######################################################################

# gerar metricas das threads
# baseada nos pares host:instanc

function buildBoundedQueueThreadPoolMetricsFunction {
        arrFile=(""); count=0;
        echo " " > $DATA_DIR/command.txt;
        LAST_ERROR="AAAAAAAAAAAAAAAAAAAA"

        # com o objetivo de executas esta tarefa com o minimo
        # possivel de iteracoes com a API do Jboss, todos os
        # comando serao executados dentro de um batch que
        # redirecionara o output de cada linha para um arquivo
        # que sera nomaeado com o seguinte formato:
        # buildDatasourceMetrics:$host:$instance:$datasource

        for line in $(cat $DATA_DIR/bounded_queue_thread_pool.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                pool=$(echo $line |awk -F':' '{print $3}')
                file_tmp="$DATA_DIR/buildBoundedQueueThreadPoolMetrics:$host:$instance:$pool"
                arrFile[$count]="$file_tmp"
                echo "/host=$host/server=$instance/subsystem=threads/bounded-queue-thread-pool=$pool:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt;

                count=$(($count + 1))

        done

        $CMD --file=$DATA_DIR/command.txt

        echo "" > $DATA_DIR/bounded_queue_thread_pool_metric.txt
        for file in $(echo ${arrFile[@]})
        do
                if [ $(echo $file |grep "$LAST_ERROR") ]; then continue; fi

                INSTANCE=$(echo $file |awk -F':' '{print $3}')
                HOST=$(echo $file |awk -F':' '{print $2}')
                POOL=$(echo $file |awk -F':' '{print $4}')

                # caso a execucao do comando tenha resultado em erro
                # o comando sera removido do arquivo de batch "command.txt"
                # e esse sera executado novamente

                if [[ $(grep -i 'Failed' $file |wc -l) -gt 0 || ! -f $file ]]; then
                        echo "Error! $HOST:$INSTANCE"
                        echo "Removendo $file do command.txt"
                        echo "Executando novo command.txt"

                        removeFromCommand "$DATA_DIR/command.txt" $file
                        LAST_ERROR="$HOST:$INSTANCE"
                        $CMD --file=$DATA_DIR/command.txt

                else
                        QUEUE_MAX=$(grep -w queue-length $file  |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                        QUEUE_SIZE=$(grep -w queue-size $file |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')

                        echo "$(eval $TIMESTAMP) HTTPTHREAD $ENVIRONMENT $HOST $APP_SERVER $INSTANCE $POOL $QUEUE_MAX $QUEUE_SIZE" >> $DATA_DIR/bounded_queue_thread_pool_metric.txt &&rm -rf $file

                fi

        done

        cat $DATA_DIR/bounded_queue_thread_pool_metric.txt

}

# gerar metricas da JVM
# baseada nos pares host:instance

function buildJVMMemoryMetricsFunction {
        arrFile=(""); count=0;
        echo "" > $DATA_DIR/command.txt
        LAST_ERROR="AAAAAAAAAAAAAAAAAAAA"

        # com o objetivo de executas esta tarefa com o minimo
        # possivel de iteracoes com a API do Jboss, todos os
        # comando serao executados dentro de um batch que
        # redirecionara o output de cada linha para um arquivo
        # que sera nomeado com o seguinte formato:
        # buildJVMMemoryMetrics:$host:$instance

        for line in $(cat $DATA_DIR/server.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                file_tmp="$DATA_DIR/buildJVMMemoryMetrics:$host:$instance"
                arrFile[$count]="$file_tmp"
                echo "/host=$host/server=$instance/core-service=platform-mbean/type=memory:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt

                count=$(($count + 1))

        done

        $CMD --file=$DATA_DIR/command.txt

        for file in $(echo ${arrFile[@]}); do
                if [ $(echo $file |grep "$LAST_ERROR") ]; then continue; fi

                INSTANCE=$(echo $file |awk -F':' '{print $3}')
                HOST=$(echo $file |awk -F':' '{print $2}')

                if [[ $(grep -i 'Failed' $file |wc -l) -gt 0 || ! -f $file ]]; then
                        echo "Error! $HOST:$INSTANCE"
                        echo "Removendo $file do command.txt"
                        echo "Executando novo command.txt"

                        removeFromCommand "command.txt" $file
                        LAST_ERROR="$HOST:$INSTANCE"
                        $CMD --file=$DATA_DIR/command.txt

                else
                        HEAP_MAX=$(grep -w "\"heap-memory-usage\"" -A 5 $file   |grep max |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g' |sed 's/L//g')
                        HEAP_USED=$(grep -w "\"heap-memory-usage\"" -A 5 $file  |grep used |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g'|sed 's/L//g')
                        PERMGEN_MAX=$(grep -w "\"non-heap-memory-usage\"" -A 5 $file    |grep max |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g' |sed 's/L//g')
                        PERMGEN_USED=$(grep -w "\"non-heap-memory-usage\"" -A 5 $file   |grep used |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g'|sed 's/L//g')
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        HOST=$(echo $file |awk -F':' '{print $2}')
                        TARGET=$(grep "$HOST:$INSTANCE:" $DATA_DIR/server_group.txt |awk -F':' '{print $3}')

                        echo "$(eval $TIMESTAMP) JVMMEMORIA $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $HEAP_MAX $HEAP_USED $PERMGEN_MAX $PERMGEN_USED" >> $DATA_DIR/jvm_metric.txt && rm -rf $file

                fi

        done

        cat $DATA_DIR/jvm_metric.txt

}

# gerar metricas dos datasources
# baseada nos pares host:instance

function buildDatasourceMetricsFunction {
        arrFile=(""); count=0;
        echo " " > $DATA_DIR/command.txt;
        LAST_ERROR="AAAAAAAAAAAAAAAAAAAA"

        # com o objetivo de executas esta tarefa com o minimo
        # possivel de iteracoes com a API do Jboss, todos os
        # comando serao executados dentro de um batch que
        # redirecionara o output de cada linha para um arquivo
        # que sera nomaeado com o seguinte formato:
        # buildDatasourceMetrics:$host:$instance:$datasource

        for line in $(cat $DATA_DIR/datasource.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                datasource=$(echo $line |awk -F':' '{print $3}')
                datasourceKind=$(echo $line |awk -F':' '{print $4}')
                file_tmp="$DATA_DIR/buildDatasourceMetrics:$host:$instance:$datasource"
                arrFile[$count]="$file_tmp"
                if [ $datasourceKind == 'data-source' ]; then
                        echo "/host=$host/server=$instance/subsystem=datasources/data-source=$datasource/statistics=pool:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt;

                else
                        echo "/host=$host/server=$instance/subsystem=datasources/xa-data-source=$datasource/statistics=pool:read-resource(include-runtime=true) > $file_tmp" >> $DATA_DIR/command.txt;

                fi

                count=$(($count + 1))

        done

        $CMD --file=$DATA_DIR/command.txt

        echo "" > $DATA_DIR/datasource_metric.txt
        
        for file in $(echo ${arrFile[@]})
        do
                if [ $(echo $file |grep "$LAST_ERROR") ]; then continue; fi

                INSTANCE=$(echo $file |awk -F':' '{print $3}')
                HOST=$(echo $file |awk -F':' '{print $2}')

                # caso a execucao do comando tenha resultado em erro
                # o comando sera removido do arquivo de batch "server_group_command.txt"
                # e esse sera executado novamente

                if [[ $(grep -i 'Failed' $file |wc -l) -gt 0 || ! -f $file ]]; then
                        echo "Error! $HOST:$INSTANCE"
                        echo "Removendo $file do command.txt"
                        echo "Executando novo command.txt"

                        removeFromCommand "$DATA_DIR/command.txt" $file
                        LAST_ERROR="$HOST:$INSTANCE"
                        $CMD --file=$DATA_DIR/command.txt

                else
                        POOL_USED=$(grep -w InUseCount $file  |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                        POOL_FREE=$(grep -w AvailableCount $file |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                        POOL_MAX=$(($POOL_USED + $POOL_FREE))
                        INSTANCE=$(echo $file |awk -F':' '{print $3}')
                        HOST=$(echo $file |awk -F':' '{print $2}')
                        POOL=$(echo $file |awk -F':' '{print $4}')
                        TARGET=$(grep "$HOST:$INSTANCE:" $DATA_DIR/server_group.txt |awk -F':' '{print $3}')

                        echo "$(eval $TIMESTAMP) DATASOURCE $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $POOL $POOL_MAX $POOL_USED $POOL_FREE" >> $DATA_DIR/datasource_metric.txt &&rm -rf $file

                fi

        done

        cat $DATA_DIR/datasource_metric.txt

}

# gerar metricas dos datasources
# baseada nos pares host:instance

function buildHttpMetricsFunction() {
        arrFile=(""); count=0;
        echo " " > $DATA_DIR/command.txt
        LAST_ERROR="AAAAAAAAAAAAAAAAAAA"

        for line in $(cat $DATA_DIR/application.txt); do
                host=$(echo $line |awk -F':' '{print $1}')
                instance=$(echo $line |awk -F':' '{print $2}')
                application=$(echo $line |awk -F':' '{print $3}')
                file_tmp="$DATA_DIR/buildHttpMetrics:$host:$instance:$application"
                arrFile[$count]="$file_tmp"
                echo "/host=$host/server=$instance/deployment=$application/subsystem=web:read-attribute(name=active-sessions) > $file_tmp" >> $DATA_DIR/command.txt;
                count=$(($count + 1))

        done

        $CMD --file=$DATA_DIR/command.txt

        echo " " > $DATA_DIR/http_metric.txt
        
        for file in $(echo ${arrFile[@]})
        do
                if [ $(echo $file |grep "$LAST_ERROR") ]; then continue; fi

                INSTANCE=$(echo $file |awk -F':' '{print $3}')
                HOST=$(echo $file |awk -F':' '{print $2}')

                if [[ $(grep -i 'Failed' $file |wc -l) -gt 0 || ! -f $file ]]; then
                        echo "Error! $HOST:$INSTANCE"
                        echo "Removendo $file do command.txt"
                        echo "Executando novo command.txt"
                        
                        removeFromCommand "$DATA_DIR/command.txt" $file
                        #LAST_ERROR="$HOST:$INSTANCE"
                        $CMD --file=$DATA_DIR/command.txt

                else
                        return=$(grep -w result $file 2> /dev/null |awk '{print $NF}' |sed 's/"//g' |sed 's/,//g')
                        CONNECTION=0
                        if [[ $return =~ "^[0-9]+$" ]]; then CONNECTION=$return; fi
                        APPLICATION=$(echo $file |awk -F':' '{print $4}')
                        TARGET=$(grep "$HOST:$INSTANCE:" $DATA_DIR/server_group.txt |awk -F':' '{print $3}')
                        echo "$(eval $TIMESTAMP) HTTPSESSION $ENVIRONMENT $HOST $APP_SERVER $TARGET $INSTANCE $APPLICATION $CONNECTION" >> $DATA_DIR/http_metric.txt && rm -rf $file

                fi

        done

        cat $DATA_DIR/http_metric.txt
        
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

        getHostList)
                cat $DATA_DIR/hosts.txt |sort |uniq;
        ;;

        getInstanceList)
                awk -F':' '{print $2}' $DATA_DIR/server.txt |sort |uniq

        ;;

        getApplicationList)
                getApplicationListFunction
        ;;

        getServerGroupList)
                getServerGroupListFunction
        ;;

        getDatasourceList)
                awk -F':' '{print $3}' $DATA_DIR/datasource.txt |sort |uniq
        ;;

        buildBase)
                buildHostListFunction && buildInstanceListFunction && buildServerGroupListFunction && buildBoundedQueueThreadPoolListFunction && buildApplicationListFunction && buildDatasourceListFunction
        ;;

        buildMetrics)
                getServerGroupListFunction
                buildJVMMemoryMetricsFunction
                buildDatasourceMetricsFunction
                getApplicationListFunction
                buildHttpMetricsFunction
                buildBoundedQueueThreadPoolMetricsFunction

        ;;
esac

if [ -f ${PIDFILE} ]; then
    rm ${PIDFILE}
fi
