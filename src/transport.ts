import {Duplex, Transform} from 'stream'
import Redis = require('ioredis')
import {Message} from './messages'

export interface Transport extends NodeJS.ReadWriteStream {
    send(msg: Message);
    onmessage(callback: (msg: Message) => any);
}

export class RedisTransport extends Duplex implements Transport {
    private emitter: IORedis.Redis;
    // private receiver: IORedis.Redis;
    // private channelListeners: { [channel: string]: Function[] } = {};
    // private patternListeners: { [pattern: string]: Function[] } = {};
    private mailbox: IORedis.Redis;
    private nodeId: string;

    constructor(nodeId){
        super({objectMode: true});
        this.nodeId = nodeId;
        this.emitter = new Redis();
        this.mailbox = new Redis();
        // this.receiver = new Redis();
        // this.receiver.on('pmessage', this.handlePatternEvent.bind(this));
        // this.receiver.on('message', this.handleEvent.bind(this));        
    }

    send(msg: Message){

    }

    onmessage(cb){
        
    }
}