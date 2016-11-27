import * as Redis from 'ioredis'
import { AbstractTransport } from '../transport';
import { Stage } from '../stage';
import { Message } from '../messages';


export class RedisTransport extends AbstractTransport {
    private emitter: Redis.Redis;
    private receiver: Redis.Redis;
    private listener: Redis.Redis
    // private channelListeners: { [channel: string]: Function[] } = {};
    // private patternListeners: { [pattern: string]: Function[] } = {};
    private mailbox: Redis.Redis;
    private mailboxKey: string;
    // protected ended: boolean;
    protected _stopped: boolean = false;

    constructor(stage: Stage, encoder?, decoder?, options?: Redis.RedisOptions) {
        super(stage, encoder, decoder);
        this.emitter = new Redis(options);
        this.mailbox = new Redis(options);
        this.mailboxKey = `mailbox:${Stage.current.id}`


        setImmediate(() => this.pollMessage());
        // this.receiver.psubscribe('')
        // this.receiver.on('pmessage', () => this.handlePatternEvent());
        this.on('prefinish', () => {
            this._stopped = true
            this.emitter.disconnect();
            this.mailbox.disconnect();
        })
    }

    pollMessage() {
        if (this._stopped) {
            return;
        }
        this.mailbox.blpop(this.mailboxKey, 10).then((val) => {
            if (!val) {
                //timeouts   
                return setImmediate(() => this.pollMessage());
            }

            var [key, message] = val;

            if (this.push(this.decoder(message))) {
                return setImmediate(() => this.pollMessage());
            } else {
                this.once('readable', () => this.pollMessage());
            }
        }).catch(console.error);
    }

    _read() {

    }

    _write(msg: Message, enc, done) {
        this.emitter.rpush(`mailbox:${msg.to}`, this.encoder(msg)).then(done)
    }
}