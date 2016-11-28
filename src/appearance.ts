import { Actor } from './actor'
import Promise = require('bluebird')
import { Stage } from './stage'
import { Scenario } from './scenario'
import { Message, MessageType, InvocationMessage, ResultMessage, ErrorMessage, EventMessage } from './messages'
import { EventEmitter } from 'events'
import { Reference } from './reference';
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


/**
 * Activation of actor in system
 * contains some runtime information
 */
export class Appearance {
    public readonly id: any;
    public processing: boolean = false;
    public reference: Reference;
    public reentrant: boolean = false;
    private mailbox: Message[];
    private execute: (msg: Message) => any = serializedExecutor;
    public readonly actor: Actor;

    constructor(actor: Actor, reentrant = false) {
        this.actor = actor;
        if (reentrant) {
            this.execute = reentrantExecutor
        }
    }

    handleInvocation(message: InvocationMessage) {
        if (this.processing)
            this.mailbox.push(message);
        else
            this.execute(message);

    }
    sendError(to: any, error:any, reqid:number) {
        return {
            type: MessageType.error, 
            error: error, 
            reqid: reqid
        }
    }

    run(message: InvocationMessage) {
        
        if (typeof this.actor[message.method] != 'function') {
            return Scenario.sendMessage({
                type: MessageType.error, 
                to: message.from, 
                error: "no such method", 
                reqid: message.reqid 
            });
        }
        try {
            var result = this.actor[message.method].apply(this.actor, message.params);
        } catch (err) {
            return Scenario.sendMessage({
                to: message.from, 
                type: MessageType.error, 
                error: err, 
                reqid: message.reqid 
            });
        }

        // send back
        // if result is a promise
        if (typeof result.then == 'function') {
            result.then(
                (data) =>
                    Scenario.sendMessage({
                        to: message.from, 
                        type: MessageType.result, 
                        result: result, 
                        reqid: message.reqid 
                    })
            ).catch(
                (err) =>
                    Scenario.sendMessage({
                        to: message.from, 
                        type: MessageType.error, 
                        error: err, 
                        reqid: message.reqid }));
        } else {
            Scenario.sendMessage({
                to: message.from, 
                type: MessageType.result, 
                result: result, 
                reqid: message.reqid 
            });
        }
        return
    }
}