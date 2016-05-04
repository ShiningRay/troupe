import * as Redis from 'ioredis';
import {IActor, resolve} from './core'
import {Node, World} from './cluster'
import {ActorProxy} from './proxy'

var subscriber: IORedis.Redis;

/**
 * router outside actor's event to proxy
 */
export class EventRouter {
    private eventChannel: IORedis.Redis;
    private channelPrefix: string;
    private _registry: { [id: string]: ActorProxy };
    private _currentNode:Node;
    
    constructor() {
        this._currentNode = Node.current();
        this.eventChannel = new Redis();
        this.channelPrefix = `${this._currentNode.id}#`;
        this.eventChannel.psubscribe(`${this.channelPrefix}*`)
        this.eventChannel.on('pmessage', this.handleEvent.bind(this));
    }

    handleEvent(channel: string, message: string) {
        let [node, id, eventName] = channel.split(/[#\/.]/);
        if (node == this._currentNode.id) {
            let actor = resolve(id);

            if (actor) {
                actor.emit(eventName, JSON.parse(message));
            } else {
                console.log('cannot find that actor with id', id);
            }
        }
    }
    
    dispose(){
        this.eventChannel.disconnect();
    }
}

/**
 * publish events(js like events, not messages) to *remote* listeners
 */
export function publish(actor: IActor, eventName: string, args: any[]) {
    eventRouter.publishEvent(actor, eventName, args);
}
