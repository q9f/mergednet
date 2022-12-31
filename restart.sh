function Log() {
	echo
	echo "--> $1"
}
function PrepareEnvironment() {
	Log "Cleaning Environment"
	killall -9 geth 
	pkill -9 -f "lodestar.js beacon"
	pkill -9 -f "lodestar.js validator"
	git clean -fxd
	rm execution/bootnodes.txt consensus/bootnodes.txt

	test -d logs || mkdir logs
	cp -R consensus/validator_keys consensus/validator_keys_1

	my_ip=`curl ifconfig.me 2>/dev/null` && Log "my_ip=$my_ip"
}
function InitGeth()
{
	Log "Initializing geth $1"
	geth init \
	  --datadir "./data/execution/$1" \
	  ./execution/genesis.json
}

function RunGeth()
{
	Log "Running geth $1 on port $((8551 + $1))"
	local bootnodes=$(cat execution/bootnodes.txt 2>/dev/null | tr '\n' ',')
	echo "Geth Bootnodes = $bootnodes"
	nohup geth \
	  --networkid 39677693 \
	  --datadir "./data/execution/$1" \
	  --authrpc.port $((8551 + $1)) \
	  --port $((30303 + $1)) \
	  --bootnodes=$bootnodes \
	  > ./logs/geth_$1.log &
	sleep 1 # Set to 5 seconds to allow the geth to bind to the external IP before reading enode
	#local variablename="bootnode_geth_$1"
	#export $variablename=`geth attach --exec "admin.nodeInfo.enode" data/execution/$1/geth.ipc | sed s/^\"// | sed s/\"$//`
	#Log "$variablename = ${!variablename}"
	#echo ${!variablename} >> execution/bootnodes.txt
	local my_enode=$(geth attach --exec "admin.nodeInfo.enode" data/execution/$1/geth.ipc | sed s/^\"// | sed s/\"$//)
	echo $my_enode >> execution/bootnodes.txt
}
function StoreGethHash() {
	genesis_hash=`geth attach --exec "eth.getBlockByNumber(0).hash" data/execution/0/geth.ipc | sed s/^\"// | sed s/\"$//`

	echo $genesis_hash > execution/genesis_hash.txt
	echo $genesis_hash > consensus/deposit_contract_block.txt
	Log "genesis_hash = $genesis_hash"
}
function GenerateGenesisSSZ()
{
	Log "Generating Beaconchain Genesis"
	./eth2-testnet-genesis merge \
	  --config "./consensus/config.yaml" \
	  --eth1-config "./execution/genesis.json" \
	  --mnemonics "./consensus/mnemonic.yaml" \
	  --state-output "./consensus/genesis.ssz" \
	  --tranches-dir "./consensus/tranches"
}
function RunBeacon() {
	Log "Running Beacon $1"
	local bootnodes=`cat consensus/bootnodes.txt 2>/dev/null | grep . | tr '\n' ',' | sed s/,$//g`
	echo "Beacon Bootnodes = $bootnodes"
	
	nohup ./lodestar beacon \
	  --suggestedFeeRecipient "0xCaA29806044A08E533963b2e573C1230A2cd9a2d" \
	  --execution.urls "http://127.0.0.1:$((8551 + $1))" \
	  --jwt-secret "./data/execution/$1/geth/jwtsecret" \
	  --dataDir "./data/consensus/$1" \
	  --paramsFile "./consensus/config.yaml" \
	  --genesisStateFile "./consensus/genesis.ssz" \
	  --enr.ip 127.0.0.1 \
	  --rest.port $((9596 + $1)) \
	  --port $((9000 + $1)) \
	  --network.connectToDiscv5Bootnodes true \
	  --logLevel $LogLevel \
	  --bootnodes=$bootnodes \
	  > ./logs/beacon_$1.log &

	sleep 1
	echo Waiting for Beacon enr ...
	local my_enr=`curl http://localhost:$((9596 + $1))/eth/v1/node/identity 2>/dev/null | jq -r ".data.enr"`
	while [[ -z $my_enr ]]
	do
		sleep 1
		local my_enr=`curl http://localhost:$((9596 + $1))/eth/v1/node/identity 2>/dev/null | jq -r ".data.enr"`
	done
	echo "My Enr = $my_enr"
	echo $my_enr >> consensus/bootnodes.txt
}

function CheckGeth()
{
	echo Checking Geth $1
	test -z $my_ip || my_ip=`curl ifconfig.me 2>/dev/null` && Log "my_ip=$my_ip"
	geth attach --exec "admin.nodeInfo.enode" data/execution/$1/geth.ipc | sed s/^\"// | sed s/\"$//
	geth attach --exec "admin.peers" data/execution/$1/geth.ipc | grep "remoteAddress" | grep $my_ip
}
function CheckBeacon()
{
	Log "Checking Beacon $1"
	echo My ID: `curl http://localhost:$((9596 + $1))/eth/v1/node/identity 2>/dev/null | jq -r ".data.peer_id"`
	echo My enr: `curl http://localhost:$((9596 + $1))/eth/v1/node/identity 2>/dev/null | jq -r ".data.enr"`
	echo Peer Count: `curl http://localhost:$((9596 + $1))/eth/v1/node/peers 2>/dev/null | jq -r ".meta.count"`
	curl http://localhost:$((9596 + $1))/eth/v1/node/syncing 2>/dev/null | jq
}
function CheckAll()
{
	CheckGeth 0; CheckGeth 1; CheckGeth 2; CheckGeth 3
	CheckBeacon 0; CheckBeacon 1; CheckBeacon 2; CheckBeacon 3
}
function RunValidator()
{
	Log "Running Validators $1"
	cp -R consensus/validator_keys consensus/validator_keys_$1
	nohup ./lodestar validator \
	  --dataDir "./data/consensus/$1" \
	  --suggestedFeeRecipient "0xCaA29806044A08E533963b2e573C1230A2cd9a2d" \
	  --graffiti "YOLO MERGEDNET GETH LODESTAR" \
	  --paramsFile "./consensus/config.yaml" \
	  --importKeystores "./consensus/validator_keys_$1" \
	  --importKeystoresPassword "./consensus/validator_keys_$1/password.txt" \
	  --logLevel $LogLevel \
	  > ./logs/validator_$1.log &

}

#git clone https://github.com/q9f/mergednet.git
#cd mergednet
LogLevel=debug
PrepareEnvironment

InitGeth 0
RunGeth 0
InitGeth 1
RunGeth 1
InitGeth 2
RunGeth 2
InitGeth 3
RunGeth 3

StoreGethHash
GenerateGenesisSSZ

RunBeacon 0
RunBeacon 1
RunBeacon 2
RunBeacon 3

sleep 5

RunValidator 0

CheckAll

echo "
clear && tail -f logs/geth_0.log -n1000
clear && tail -f logs/geth_1.log -n1000
clear && tail -f logs/beacon_0.log -n1000
clear && tail -f logs/beacon_1.log -n1000
clear && tail -f logs/validator_0.log -n1000
clear && tail -f logs/validator_1.log -n1000

curl http://localhost:9596/eth/v1/node/identity | jq
curl http://localhost:9696/eth/v1/node/identity | jq

curl http://localhost:9596/eth/v1/node/peers | jq
curl http://localhost:9696/eth/v1/node/peers | jq

curl http://localhost:9596/eth/v1/node/syncing | jq
curl http://localhost:9696/eth/v1/node/syncing | jq
"