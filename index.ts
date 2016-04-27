import {sealed} from './lib/sealed';
import Redis = require('ioredis')
var EventEmitter = require('events')
import shortid = require('shortid')
import * as Promise from 'bluebird'
/**
 * we can treat the main process as an actor, too.
 */
export declare var DefaultActor: Actor;

export interface Ref {
    node: string;
    id: string;
}
export type Pid = string | Ref;

export interface IActor {
    pid: string;
    onmessage(message?: any);
    emit(eventName: string, ...args: any[]);
    onexit();
}

type IActorCtor = (new (...args: any[]) => IActor);
interface RemoteCallMessage {
    from: Ref;
    to: Ref;
    reqid: number;
    method: string;
    args: any[];
}

interface RemoteResultMessage {
    from: Ref;
    to: Ref;
    reqid: number;
    result: any;
}

interface ErrorResultMessage {
    from: Ref;
    to: Ref;
    reqid: number;
    error: any;
}
interface RequestSpec {
    resolve: Function;
    reject: Function;
    timeout: number | NodeJS.Timer;
}
// Base Actor Model 
// Publish Events to outside proxy via redis channel
export class Actor implements IActor {
    //   private _id; // the unique id
    //   private _dispatcher;
    //   private _registry;

    /**
     * actor identifier, unique in one node
     */
    private _pid: string;

    __reqId: number = 0;
    __requests: { [id: number]: RequestSpec } = {};
    __send(pid: Pid, args: any) {
        Actor.send(pid, args);
    }

    /**
     * send a remote procedure call to remote actor 
     * @param pid, Actor's pid
     */
    __call(pid: Pid, method: string, args: any[]): PromiseLike<any> {
        console.log(Actor.node, this.pid, 'call', pid, method, args);
        return new Promise((resolve, reject) => {
            var reqId = this.__reqId++;
            this.__send(pid, { type: 'call', reqid: reqId, method: method, args: args, from: { node: Actor.node, id: this.pid } });
            this.__requests[reqId] = {
                resolve: resolve,
                reject: reject,
                timeout: setTimeout(this.__timeout, 10000, reqId, this) // TODO: move timeout to option                
            }
        });
    }

    // handle timout for rpc
    __timeout(reqId: number, self?: Actor) {
        if (!self) {
            self = this;
        }
        var req = self.__requests[reqId];
        if(req) {
            console.log(Actor.node, self.__requests);
            delete self.__requests[reqId];
            req.reject(new Error(`${self.pid} call remote method timeout ${reqId}`));
        } else {
            console.log("Timeout but cannot found corresponding requestspec");
        }
    }

    /**
     * handle messages, 
     * TODO: move each message handler to own function 
     */
    onmessage(message: any) {
        var req: RequestSpec;

        // handle remote invokation
        switch (message.type) {
            // I'm being invoked
            case 'call':
                if (typeof this[message.method] != 'function') {
                    return Actor.send(message.from, { type: 'error', error: "no such method", reqid: message.reqid });
                }
                try {
                    var result = this[message.method].apply(this, message.args);
                } catch (err) {
                    return Actor.send(message.from, { type: 'error', error: err, reqid: message.reqid });
                }

                // if result is a promise
                if (typeof result.then == 'function') {
                    result.then(
                        (data) =>
                            Actor.send(message.from, { type: 'result', result: result, reqid: message.reqid })
                    ).catch(
                        (err) =>
                            Actor.send(message.from, { type: 'error', error: err, reqid: message.reqid }));
                } else {
                    Actor.send(message.from, { type: 'result', result: result, reqid: message.reqid });
                }
                break;
            // I'm telling a result for previous my own invokation to remote actor
            case 'result':
                req = this.__requests[message.reqid];
                if (req) {
                    clearTimeout(req.timeout as number);
                    delete this.__requests[message.reqid];
                    req.resolve(message.result);
                } else {
                    console.log('cannot find corresponding request')
                }
                break;
            case 'error':
                req = this.__requests[message.reqid];
                if (req) {
                    clearTimeout(req.timeout as number);
                    delete this.__requests[message.reqid];
                    req.reject(message.error);
                } else {
                    console.log('cannot find corresponding request')
                }
                break;
            default:
                break;
        }
    }

    /**
     * the actor is exiting, handle cleanup job here
     */
    onexit() {

    }
    /**
     * broadcast events to remote subscribers
     * because in javascript, developers love to do event listening, 
     */
    emit(eventName: string, ...args: any[]) {
        Actor.publishEvent(this, eventName, args);
    }
    // this should be @sealed and @readonly after initialized
    public get pid(): string {
        return this._pid;
    }

    static dispatcher: Dispatcher;
    static _actors: { [name: string]: IActor } = {};

    /**
     * give the actor an unique name
     */
    static register(name: string, object: IActor) {
        //   if(typeof object == "undefined"){
        //       object = name;
        //       name = shortid.generate();
        //   }
        if (this._actors[name]) {
            throw new Error('name is already taken')
        }
        var oid = object['_pid'];
        delete this._actors[oid];
        this._actors[name] = object;
        object['_pid'] = name;
    }

    /**
     * publish events(js like events, not messages) to *remote* listeners
     */
    static publishEvent(actor: IActor, eventName: string, args: any[]) {
        this.dispatcher.publishEvent(actor, eventName, args);
    }

    /**
     * get the actor according to the name
     */
    static resolve(name: string) {
        return this._actors[name];
    }

    /**
     * send a message to the actor with corresponding id
     * the actor can be located remotely
     */
    static send(pid: Pid, args) {
        if (typeof pid === 'string') {
            //local message
            var actor = this.resolve(pid);
            return actor.onmessage(args);
        }
        return this.dispatcher.send(pid as Ref, args);
    }

    /**
     * RPC-style call, when call from outside actor, we treat it from default actor
     */
    static invoke(pid: Pid, method: string, args: any[]): PromiseLike<any> {
        return DefaultActor.__call(pid, method, args);
    }

    /**
     * start an Actor and add it to the registry
     */
    static start(ctor: IActorCtor, args?: any[], name?: string): IActor {
        // register self to the registry
        // dispatcher will find this object from registry
        // Actor.register(this);
        if(!name){
            name = shortid.generate();
        }
        
        var actor = new ctor(...args);
        actor['_pid'] = name;
        this._actors[name] = actor;
        return actor;
    }
    static node: string;
    /**
     * start the Actor system
     */
    static init(cb?: (...args: any[]) => any) {
        this.node = shortid.generate();
        this.dispatcher = new Dispatcher(this.node);
        DefaultActor = <Actor>Actor.start(Actor, [], 'default');

        process.on('beforeExit', (code) => {
            this.dispatcher.dispose();
        });
        if (cb) {
            cb(this.dispatcher);
        }
    }
}

/**
 * Dispatcher for routing messages to correct actor
 */
class Dispatcher {
    private redis: IORedis.Redis;
    public processId: string;
    private mailbox: IORedis.Redis;

    constructor(processId: string) {
        // super();
        this.redis = new Redis();
        // this.processId = directory.register();
        this.processId = processId;
        this.mailbox = new Redis();
        this.receive();
    }

    /**
     * pull message from the mailbox(on redis)
     */
    receive(self?: Dispatcher) {
        if (!self) {
            self = this;
        }

        self.mailbox.blpop(self.processId, 0).then((reply) => {
            var args = JSON.parse(reply[1]);
            console.log('receive from queue', reply);
            self.process(args[0], args[1]);
            process.nextTick(self.receive, self);
        }).catch((err) => {
            console.log('pop from queue error', err);
            console.log('pop from queue error', err.stack);
            process.nextTick(self.receive, self);
        });
    }

    dispose() {
        this.redis.srem("nodes", this.processId);
        delete this.mailbox;
    }

    /**
     * process a mail
     */
    process(pid: string, message: any) {
        var actor = Actor.resolve(pid);
        if (actor) {
            actor.onmessage(message);
        } else {
            console.log(Actor._actors);
            console.log('cannot find that actor', pid);
        }
    }

    /**
     * send message to an actor
     */
    send(ref: Ref, message: any) {
        if (!ref.node || ref.node == this.processId) {
            // local message
            return this.process(ref.id, message);
        } else {
            return this.redis.lpush(ref.node, JSON.stringify([ref.id, message]));
        }
    }

    /**
     * publish an event
     */
    publishEvent(actor: IActor, eventName: string, args: any[]) {
        var channel = `${this.processId}#${actor.pid}.eventName`;
        this.redis.publish(channel, eventName, args);
    }
}
