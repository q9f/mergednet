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

	test -d logs || mkdir logs
	cp -R consensus/validator_keys consensus/validator_keys_1
}

#git clone https://github.com/q9f/mergednet.git
#cd mergednet
LogLevel=info
PrepareEnvironment

Log "Initializing geth 0"
geth init \
  --datadir "./data/execution/0" \
  ./execution/genesis.json

Log "Initializing geth 1"
geth init \
  --datadir "./data/execution/1" \
  ./execution/genesis.json
  
Log "Running geth 0"
nohup geth \
  --networkid 39677693 \
  --datadir "./data/execution/0" \
  > ./logs/geth_0.log &

sleep 1
genesis_hash=`geth attach --exec "eth.getBlockByNumber(0).hash" data/execution/0/geth.ipc | sed s/^\"// | sed s/\"$//`
bootnode_geth_0=`geth attach --exec "admin.nodeInfo.enode" data/execution/0/geth.ipc | sed s/^\"// | sed s/\"$//`

echo $genesis_hash > execution/genesis_hash.txt
echo $genesis_hash > consensus/deposit_contract_block.txt
Log "genesis_hash = $genesis_hash"

echo $bootnode_geth_0 > execution/bootnodes.txt

Log "bootnode_geth_0 = $bootnode_geth_0"

Log "Running geth 1"
nohup geth \
  --networkid 39677693 \
  --datadir "./data/execution/1" \
  --authrpc.port 8651 \
  --port 31303 \
  --bootnodes $bootnode_geth_0 \
  > ./logs/geth_1.log &
sleep 1

Log "Connected to Geth 0 at $(geth attach -exec "admin.peers" data/execution/1/geth.ipc | grep $bootnode_geth_0)"
bootnode_geth_1=`geth attach --exec "admin.nodeInfo.enode" data/execution/1/geth.ipc | sed s/^\"// | sed s/\"$//`
echo $bootnode_geth_1 >> execution/bootnodes.txt
Log "bootnode_geth_1 = $bootnode_geth_1"

Log "Generating Beaconchain Genesis"
./eth2-testnet-genesis merge \
  --config "./consensus/config.yaml" \
  --eth1-config "./execution/genesis.json" \
  --mnemonics "./consensus/mnemonic.yaml" \
  --state-output "./consensus/genesis.ssz" \
  --tranches-dir "./consensus/tranches"

Log "Running Beacon 0"
nohup ./lodestar beacon \
  --suggestedFeeRecipient "0xCaA29806044A08E533963b2e573C1230A2cd9a2d" \
  --execution.urls "http://127.0.0.1:8551" \
  --jwt-secret "./data/execution/0/geth/jwtsecret" \
  --dataDir "./data/consensus/0" \
  --paramsFile "./consensus/config.yaml" \
  --genesisStateFile "./consensus/genesis.ssz" \
  --enr.ip 127.0.0.1 \
  --network.connectToDiscv5Bootnodes true \
  --logLevel $LogLevel \
  > ./logs/beacon_0.log &

sleep 5
bootnode_beacon_0=`curl http://localhost:9596/eth/v1/node/identity 2>/dev/null | jq -r ".data.enr"`
echo $bootnode_beacon_0 > consensus/bootnodes.txt
Log "bootnode_beacon_0 = $bootnode_beacon_0"

Log "Running Beacon 1"
nohup ./lodestar beacon \
  --suggestedFeeRecipient "0xCaA29806044A08E533963b2e573C1230A2cd9a2d" \
  --execution.urls "http://127.0.0.1:8651" \
  --jwt-secret "./data/execution/1/geth/jwtsecret" \
  --dataDir "./data/consensus/1" \
  --paramsFile "./consensus/config.yaml" \
  --genesisStateFile "./consensus/genesis.ssz" \
  --enr.ip 127.0.0.1 \
  --rest.port 9696 \
  --port 9100 \
  --network.connectToDiscv5Bootnodes true \
  --bootnodes $bootnode_beacon_0 \
  --logLevel $LogLevel \
  > ./logs/beacon_1.log &

sleep 5
bootnode_beacon_1=`curl http://localhost:9696/eth/v1/node/identity 2>/dev/null | jq -r ".data.enr"`
echo $bootnode_beacon_1 >> consensus/bootnodes.txt
Log "bootnode_beacon_1 = $bootnode_beacon_1"

Log "Running Validators 0"
nohup ./lodestar validator \
  --dataDir "./data/consensus/0" \
  --suggestedFeeRecipient "0xCaA29806044A08E533963b2e573C1230A2cd9a2d" \
  --graffiti "YOLO MERGEDNET GETH LODESTAR" \
  --paramsFile "./consensus/config.yaml" \
  --importKeystores "./consensus/validator_keys" \
  --importKeystoresPassword "./consensus/validator_keys/password.txt" \
  --logLevel $LogLevel \
  > ./logs/validator_0.log &

function RunValidator1() {
	Log "Running Validators 1"
	nohup ./lodestar validator \
	  --dataDir "./data/consensus/1" \
	  --suggestedFeeRecipient "0xCaA29806044A08E533963b2e573C1230A2cd9a2d" \
	  --graffiti "YOLO MERGEDNET GETH LODESTAR" \
	  --paramsFile "./consensus/config.yaml" \
	  --importKeystores "./consensus/validator_keys_1" \
	  --importKeystoresPassword "./consensus/validator_keys/password.txt" \
	  --server "http://127.0.0.1:9696"
	  > ./logs/validator_1.log &
}

echo "
clear && tail -f logs/geth_0.log -n1000
clear && tail -f logs/geth_1.log -n1000
clear && tail -f logs/beacon_0.log -n1000
clear && tail -f logs/beacon_1.log -n1000
clear && tail -f logs/validator_0.log -n1000
clear && tail -f logs/validator_1.log -n1000

curl http://localhost:9596/eth/v1/node/identity|jq
curl http://localhost:9696/eth/v1/node/identity|jq

curl http://localhost:9596/eth/v1/node/peers | jq
curl http://localhost:9696/eth/v1/node/peers | jq

curl http://localhost:9596/eth/v1/node/syncing 2>/dev/null && echo
curl http://localhost:9696/eth/v1/node/syncing 2>/dev/null && echo
"