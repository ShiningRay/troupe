import * as Redis from 'ioredis';
import {Pid, IActor, Ref, resolve, toRef} from './core'
import {Node, World} from './cluster'
import {ActorProxy} from './proxy'

var subscriber: IORedis.Redis;
var publisher: IORedis.Redis;

function refToChannel(ref: Ref) {
    return `${ref.node}#${ref.id}`;
}

function eventToChannel(ref: Ref, eventName: string) {
    return `${ref.node}#${ref.id}#${eventName}`;
}
/**
 * TODO: maybe we can user rabbitmq or other mq as event router backend
 */
export interface IEventRouter {
    subscribe(actor: Pid, eventName: string, cb: Function);
    publish(actor: Pid, eventName: string, args: any[]);
}
/**
 * router outside actor's event to proxy
 */
export class EventRouter implements IEventRouter {
    private emitter: IORedis.Redis;
    private receiver: IORedis.Redis;
    private channelListeners: { [channel: string]: Function[] } = {};
    private patternListeners: { [pattern: string]: Function[] } = {};

    constructor(prefix?: string) {
        this.emitter = new Redis();
        this.receiver = new Redis();
        this.receiver.on('pmessage', this.handlePatternEvent.bind(this));
        this.receiver.on('message', this.handleEvent.bind(this));
    }

    /**
     * handle pattern message from redis
     */
    private handlePatternEvent(pattern: string, channel: string, message: string) {
        let [node, id, eventName] = channel.split('#', 3);
        if (this.patternListeners[pattern]) {
            this.patternListeners[pattern].forEach(
                (cb) => cb(JSON.parse(message), eventName));
        }
    }
    /**
     * handle pattern message from redis
     */
    private handleEvent(channel: string, message: string) {
        let [node, id, eventName] = channel.split('#', 3);
        
        if (this.channelListeners[channel]) {
            this.channelListeners[channel].forEach(
                (cb) => cb(JSON.parse(message)));
        }
    }
    /**
     * local subscribe to actor proxy to listen to remote 
     * events from remote actors
     */
    subscribe(actor: Pid, eventName: string, cb: Function) {
        let ref = toRef(actor)
        let channel = `${ref.node}#${ref.id}#${eventName}`;

        if (/\*/.test(eventName)) {
            // it's a pattern 
            if (!this.patternListeners[channel]) {
                this.patternListeners[channel] = [];
            }

            this.patternListeners[channel].push(cb);
            this.receiver.psubscribe(channel);
        } else {
            if (!this.channelListeners[channel]) {
                this.channelListeners[channel] = [];
            }

            this.channelListeners[channel].push(cb);
            this.receiver.subscribe(channel);
        }
    }

    /**
     * publish events(js like events, not messages) to *remote* listeners
     */
    publish(actor: Pid, eventName: string, args: any) {
        let ref = toRef(actor);
        this.emitter.publish(eventToChannel(ref, eventName), JSON.stringify(args));
    }

    dispose() {
        this.emitter.disconnect();
        this.receiver.disconnect();
    }
}