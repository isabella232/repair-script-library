. ./src/linux/common/setup/init.sh
if [ -z "$1" ]; then 
	hello="Hello"
else
	hello=$1
fi

if [ -z "$2" ]; then
	world="World!"
else
	world=$2
fi

Log-Output "$hello $world"

exit $STATUS_SUCCESS