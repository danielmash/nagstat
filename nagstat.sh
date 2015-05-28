#!/bin/sh
#this script parse nagios services.cfg file, run dstat, parse output and send it to nagios
#
#Written 13/08/2006 by Daniel Mashonkin [dmashonkin@economicoutlook.net]
##
# ver 0.1 send dstat coma separated output to nagios via send_nsca or any other "send" script
# ver 0.2 parse services.cfg and check data from dstat for warning and critical state
# ver 0.3 rewritten to optimise performance, removed sed and awk requests in the main loop
# ver 0.4 bugfixes in coma separated dstat parameters and "-1" if no warn or crit data present
# ver 0.5 found and fixed bug in procedure of initial start and clean some expensive code
##

SERVICESCFG="/etc/nagios/services.cfg"
SERVICETEMPLATESCFG="/etc/nagios/service_templates.cfg"
DSTATTEMPLATENAME="dstat" #related template name in nagios services.cfg file
PIPEFILE="/tmp/nagstat_pipe" #pipe to read dstat data
PIDFILE="/var/run/nagstat.pid"
#HOSTNAME=`/usr/bin/hostname -s` #short hostname (if you want long change it to -f)
HOSTNAME=`/usr/bin/hostname -s` #short hostname (if you want long change it to -f)

# Gentoo Linux Users: configure the hostname in /etc/conf.d/nagios
source /etc/conf.d/nagios
NagiosHost="${NAGIOS_NSCA_HOST}"
SENDCOMMAND="/usr/bin/cat"
SENDCOMMAND="/usr/nagios/libexec/send_nsca -c /etc/nagios/send_nsca.cfg -H $NagiosHost 1> /dev/null" #NSCA

VERSION="ver 0.5"
PAUSE="0.01" # minimal pauses (sleeps) between sending check results to nagios 

if [ ${#@} -ne 0 ]; then #if any arguments
	rm -rf $PIPEFILE 
	mkfifo $PIPEFILE
	exec 0<&- #Close stdin, since the child process won't need to inherit it
	su nagios -c "$0 1>/dev/null 2>&1" &
	{ dstat --output $PIPEFILE $@ 1>/dev/null 2>&1 & echo "$!" > $PIDFILE ;};
	disown $! #detach from bash
	exit 0
fi

#### send checks
#/usr/local/nagios/bin/send_check.sh "PORTAGE" "$(/usr/local/nagios/libexec/check_portage.sh -w 1 -c 1)" "$?"
####

echo "No parameters given, start to read data from $PIPEFILE" >&2

IFS=',' #setup global delimiter (important to setup it after dstat startted)

#To run checks manually
#echo -e `hostname -s`"\tPORTAGE\t0\t"`/usr/nagios/libexec2/check_portage.sh -w 1 -c 1 2> /dev/null`| /usr/nagios/libexec/send_nsca -c /etc/nagios/send_nsca.cfg -H 192.168.2.218

#each array have the same capasity
declare -a services #services provided by dstat
declare -a headers #headers of performance data values
declare -a critical #array of critical values for all services
declare -a warning  #warning values
declare -a data #coma separated data read from dstat -o output file/pipe

logger -t $0 "=NagStat (dstat wrapper for nagios) $VERSION started"

[ -f $SERVICESCFG ] || error="Error" #check file present
if [ ! "$error" = "" ]; then
    logger -t $0 "$error: Something wrong with $SERVICESCFG?"
    exit 1
fi

logger -t $0 "=Use $SERVICESCFG"

#make specific strings from nagios configuration file
config=`sed 's/[[:blank:]]*#.*//;s/^[ \t]*//;s/[ \t]*$//;/./!d;s/[ \t]/=/' $SERVICESCFG | 
	tr '\n' ';' |      #make configuration lines
	sed 's/;};/\n/g' | #ends of lines 
	grep "=$HOSTNAME;" |
	awk -F';' '{
	for (i=1; split($i,str,"="); i++) conf[str[1]]=str[2];
	printf("%s\t%s\t\"%s\"\t%s\n",conf["use"],conf["host_name"],conf["service_description"],conf["check_command"]);
	for (x in conf) conf[x]=""
	}' | #and finally build array like conf[check_command]="check_portage" then print as we want
	sort | uniq`
	
[ -n "$config" ] || { logger -t $0 "No services for $HOSTNAME found in $SERVICESCFG. Nothing to do." && exit 1; }

#echo "---===CONFIG===---"
#echo "$templates" #IF DEBUG
#echo "******************"
#echo "$config" #IF DEBUG
#echo "******************"

#extract tokens (keywords) from config for status checking loop
tokens=`echo -n "$config" | cut -f 3 | sort | uniq | tr '\n' ','`	

logger -t $0 "=Found services $tokens"

exec 6<&0 #save stdin to descriptor 6
exec < $PIPEFILE #new stdin

read; read; #skip empty lines
read; # host
read; read;  #skip not important lines 
read -a services
read -a headers

services=(`echo -n "${services[*]}" | awk '{ print toupper($0) }' | tr -d '"'`)
headers=(`echo -n "${headers[*]}" | tr -d '"'`)
logger -t $0 "=Found that dstat can do ${services[*]}"

conf=""; token=""; warning=(); critical=(); #defaults
for service in ${services[*]} "" #for each service add warning and critical parameters in special arrays 
do
	[ -n "$service" ] && conf=`echo "$config" | grep "$service" | cut -f 4` #found tmp config
	[ -n "$conf" ] || conf="no-service-found" #if no config found for this service
	[ -n "$service" ] && { token="$service"; let 'i=1';} || let 'i+=1' #token and array index if new service

	#add parameter to array each time we check gap in services array (build same capasity arrays)
	warning[${#warning[*]}]=`echo "$conf" | 
			awk -F'!' -v i="$i" '{ if (split($2,a,",")) printf("%.0f",a[i]); else printf("-1");}'`
	critical[${#critical[*]}]=`echo "$conf" | 
			awk -F'!' -v i="$i" '{ if (split($3,a,",")) printf("%.0f",a[i]); else printf("-1");}'`
done

#echo "WARN:|${warning[*]}|" #FOR DEBUG
#echo "CRIT:|${critical[*]}|" #FOR DEBUG

header=""; perfdata=""; output="" #defaults for main string output just for first start then it cycling
sequence=`seq -s "$IFS" 0 "${#services[*]}"` #build array index to use with loop
#mail loop to read and process data

while read -a data #eternally read lines from fifo
   do
#echo "DATA:|${data[*]}|" #FOR DEBUG
	#let's build strings for all services in dstat
	for i in $sequence #foreach elements in services array by index [i]
	do
	
	if [ -n "${services[$i]}" ]; then #finish old and start new string if new service
		
	   if [ -n "$header" ]; then #if header already exist it means the end of build string
		for token in $tokens #check if we have this service in config file
		do #print previous string
		[ "\"$service\"" == "$token" ] && 
			echo -e "$header\t$state\t$service $output|$perfdata" | eval $SENDCOMMAND
		done
		sleep $PAUSE #to stop tcp stack abuse sleep between sendings
	   fi
		
		header=$HOSTNAME"\t"${services[$i]} #build new string
		service=${services[$i]}; let 'state=0'; output="OK"; perfdata=""; #defaults for new string 
	fi
	
	# if warning and critical data exist change status
	if [ -n "${warning[$i]}" ] && [ -n "${critical[$i]}" ]; then
		var=`printf "%.0f" "${data[$i]}"` #aproximate value
		[ "$var" -le "${warning[$i]}" ] || { let 'state=1'; output="WARNING"; } 
		[ "$var" -le "${critical[$i]}" ] || { let 'state=2'; output="CRITICAL"; }
		[ "${warning[$i]}" -ne "-1" ] || { let 'state=3'; output="UNKNOWN"; }
         	[ "${critical[$i]}" -ne "-1" ] || { let 'state=3'; output="UNKNOWN"; }
	fi

	perfdata=$perfdata${headers[$i]}"="${data[$i]}"," #accumulate perfdata

	done
done

exec 0<&6 6<&- #restore stdin

exit 0 #normally we never ever exit from this loop
