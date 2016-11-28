import { Actor } from './actor'
import Promise = require('bluebird')
import { Stage } from './stage'
import { Scenario } from './scenario'
import { Message, MessageType, InvocationMessage, ResultMessage, ErrorMessage, EventMessage } from './messages';
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
function serializedExecutor(message?:InvocationMessage) {
    this.processing = true;

    if (!message) {
        if (this.mailbox.length == 0) {
            this.processing = false;
            return
        }
        message = this.mailbox.shift();
    }

    // execute one message
    return this.run(message, (err) => {
        if (err) {
            if (typeof this.actor.$onError == 'function') {
                return this.actor.$onError(err, () => this.execute());
            } else {
                console.error(err);
            }
        }

        if (this.mailbox.length == 0) {
            // no remaining messages, stop processing
            this.processing = false;
        } else {
            // push job to event loop
            setImmediate(() => this.execute());
        }
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
    private mailbox: Message[] = [];
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

    run(message: InvocationMessage, next?: Function) {
        if (typeof this.actor[message.method] != 'function') {
            Scenario.sendMessage({
                type: MessageType.error,
                from: null,
                to: message.from,
                name: 'NoMethodError',
                message: "no such method " +message.method,
                reqid: message.reqid
            } as ErrorMessage);
            return next('no such method');
        }
        try {
            var result = this.actor[message.method].apply(this.actor, message.params);
        } catch (err) {
            Scenario.sendMessage({
                to: message.from,
                from: null,
                type: MessageType.error,
                name: err.name,
                message: err.message,
                stack: err.stack,
                reqid: message.reqid
            } as ErrorMessage);
            return next(err)
        }

        // send back
        // if result is a promise
        if (result && typeof result.then == 'function') {
            result.then((data) => {
                Scenario.sendMessage({
                    to: message.from,
                    from: null,
                    type: MessageType.result,
                    result: data,
                    reqid: message.reqid
                })
                next()
            }).catch((err) => {
                Scenario.sendMessage({
                    to: message.from,
                    from: null,
                    type: MessageType.error,
                    name: err.name,
                    message: err.message,
                    stack: err.stack,
                    reqid: message.reqid
                } as ErrorMessage)
                next(err)
            });
        } else {
            Scenario.sendMessage({
                to: message.from,
                from: null,
                type: MessageType.result,
                result: result,
                reqid: message.reqid
            });
            next();
        }
    }
}