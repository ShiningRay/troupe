import {Ref, IActor, resolve} from './core'

import Redis = require('ioredis');

export class MessageRouter {
    route(message){

    }
}

/**
 * Dispatcher for routing messages to correct actor
 */
export class MessageDispatcher {
    private redis: IORedis.Redis;
    public nodeId: string;
    private mailbox: IORedis.Redis;

    constructor(nodeId: string) {
        // super();
        this.redis = new Redis();
        // this.nodeId = directory.register();
        this.nodeId = nodeId;
        this.mailbox = new Redis();
        this.receive(this);
    }

    /**
     * pull message from the mailbox(on redis)
     */
    receive(self?: MessageDispatcher) {
        self.mailbox.blpop(self.nodeId, 0).then((reply) => {
            var args = JSON.parse(reply[1]);
            console.log('receive from queue', reply);
            self.process(args[0], args[1]);
            setImmediate(self.receive, self);
        }).catch((err) => {
            console.log('pop from queue error', err);
            // console.log('pop from queue error', err.stack);
            setImmediate(self.receive, self);
        });
    }

    dispose() {
        this.mailbox.disconnect();
        delete this.mailbox;
    }

    /**
     * process a mail
     */
    process(pid: string, message: any) {
        var actor = resolve(pid);
        if (actor) {
            actor.onmessage(message);
        } else {
            // console.log(Ray._actors);
            console.log('cannot find that actor', pid);
        }
    }

    /**
     * send message to an actor
     */
    send(ref: Ref, message: any) {
        if (!ref.node || ref.node == this.nodeId) {
            // local message
            return this.process(ref.id, message);
        } else {
            return this.redis.lpush(ref.node, JSON.stringify([ref.id, message]));
        }
    }
}
