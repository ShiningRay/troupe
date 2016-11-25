import { Actor } from './actor'
import Promise = require('bluebird')
import { Stage } from './stage'
import {Scenario } from './scenario'
import { Message, MessageType, InvocationMessage, ResultMessage, ErrorMessage, EventMessage } from './messages'
import {EventEmitter} from 'events'
/**
 * address
 */
class AppearanceLocation {
    stage: Stage;
}

/**
 * 
 */
function serializedExecutor(message) {
    this.processing = true;

    if (!message) {
        if (this.mailbox.length == 0) {
            this.processing = false;
            return
        }
        message = this.mailbox.shift();
    }

    // execute one message
    return this.run(message).then(() => {
        if (this.mailbox.length == 0) {
            // no remaining messages, stop processing
            this.processing = false;
        } else {
            // push job to event loop
            setImmediate(() => this.execute());
        }
    }).catch((err) => {
        this.actor.$onError(err);
    });
}

function reentrantExecutor(message) {
    return this.run(message);
}

interface RequestSpec {
    resolve: Function;
    reject: Function;
    timeout: NodeJS.Timer;
}
/**
 * remote proxy of actor
 * properties starts with `$` is restrict to current scenario
 */
export class Reference extends EventEmitter {
    public $local: boolean = false;
    public $id: any = '';
    public $target: any;
    public readonly $stage: Stage;

    private __requests: { [id: number]: RequestSpec } = {};
    private __reqId: number = 0;

    private __send(message) {
        Scenario.sendMessage(message);
    }
    public $invoke(method:string, args:any[]) {
        return new Promise((resolve, reject) => {
            var reqId = this.__reqId++;
            this.__send({
                type: MessageType.invocation,
                reqid: reqId, 
                method: method, 
                params: args,
                to: this.$target, 
                from: this.$id
            });
            let t = setTimeout(this.__timeout, 10000, reqId, this) // TODO: move timeout to option
            this.__requests[reqId] = {
                resolve: resolve,
                reject: reject,
                timeout: t
            }
            t.unref();    
        });
    }

    /**
     * handle timeout of request
     */
    private __timeout(reqId: number, self?: Reference) {
        if (!self) {
            self = this;
        }
        var req = self.__requests[reqId];
        if (req) {
            // console.log(Scenario.current(), self.__requests);
            delete self.__requests[reqId];
            req.reject(new Error(`${self} call remote method timeout ${reqId}`));
        } else {
            console.log("Timeout but cannot found corresponding requestspec");
        }
    }

    public $handleResult(message:ResultMessage){
        let req = this.__requests[message.reqid];
        if (req) {
            clearTimeout(req.timeout);
            delete this.__requests[message.reqid];
            req.resolve(message.result);
        } else {
            console.log('cannot find corresponding request', message)
        }
    }

    public $handleError(message:ErrorMessage):PromiseLike<any>{
        let req = this.__requests[message.reqid];
        if (req) {
            clearTimeout(req.timeout);
            delete this.__requests[message.reqid];
            return req.reject(message);
        } else {
            console.log('cannot find corresponding request', message)
        }        
    }
}

/**
 * Activation of actor in system
 * contains some runtime information
 */
class Appearance {
    public processing: boolean = false;
    public reference: Reference;
    public reentrant: boolean = false;
    private mailbox: Message[];
    private execute: (msg: Message) => any;
    public readonly actor: Actor;

    handleInvocation(message: InvocationMessage) {
        if (this.processing)
            this.mailbox.push(message);
        else
            this.execute(message);

    }

    run(message){
        /////
        if (typeof this.actor[message.method] != 'function') {
            return this.send(message.from, { type: 'error', error: "no such method", reqid: message.reqid });
        }
        try {
            var result = this[message.method].apply(this, message.args);
        } catch (err) {
            return send(message.from, { type: 'error', error: err, reqid: message.reqid });
        }

        // send back
        // if result is a promise
        if (typeof result.then == 'function') {
            result.then(
                (data) =>
                    send(message.from, { type: 'result', result: result, reqid: message.reqid })
            ).catch(
                (err) =>
                    send(message.from, { type: 'error', error: err, reqid: message.reqid }));
        } else {
            send(message.from, { type: 'result', result: result, reqid: message.reqid });
        }
        return        
    }    
}


class Dispatcher {
    constructor(private actor: Actor, reentrant: boolean = false) {
        if (reentrant) {
            this.execute = reentrantExecutor
        } else {
            this.execute = serializedExecutor
        }
    }

    onmessage(message: Message) {
        switch (message.type) {
            case MessageType.invocation:
                return this.handleInvocation(message);
            case MessageType.result:
                this.handleResult(message);
                return
            case MessageType.error:
                break;
            case MessageType.event:
                break;
            default:

        }
    }

    send(from, to) {

    }


    handleResult(message: ResultMessage): PromiseLike<any> {
        return this.reference.$handleResult(message);
    }

    handleError(message:ErrorMessage){
        return this.reference.$handleError(message);
    }

    run(message: Message): PromiseLike<any> {

    }    
}

/**
 * global singleton
 */
class Router {

}
