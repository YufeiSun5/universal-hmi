const aedes = require('aedes')();
const net = require('net');
const mqtt = require('mqtt');
net.createServer(aedes.handle).listen(18885, '127.0.0.1', () => {
  const publisher = mqtt.connect('mqtt://127.0.0.1:18885', {clientId:'discovery-fixture'});
  publisher.on('connect', () => {
    const Objs = Array.from({length:250}, (_,i) => ({N:`Heat.Tag${String(i).padStart(3,'0')}`, '1': i%3===0 ? i+0.5 : i%3===1 ? false : '001'}));
    publisher.publish('data/initial', JSON.stringify({PVs:{'2':new Date().toISOString(),'3':192}, Objs}), {qos:1,retain:true}, () => console.log('READY: 250 KingIO variables retained before subscriber connects'));
  });
});
