import { Ref, IActor, resolve } from './core'
import { Message, MessageType, InvocationMessage, ResultMessage, ErrorMessage, EventMessage } from './messages';
import { Scenario } from './scenario';

import Redis = require('ioredis');

export type DispatcherHandle = (message: Message) => any;

/**
 * Dispatcher for routing messages to correct actor
 */
export default function (message: Message) {
    var ref;
    switch (message.type) {
        case MessageType.invocation:
            let appearance = Scenario.findAppearance(message.to)
            appearance.handleInvocation(<InvocationMessage>message);
            break;
        case MessageType.result:
            ref = Scenario.findReference(message.to);
            ref.$handleResult(<ResultMessage>message);
            break;
        case MessageType.error:
            ref = Scenario.findReference(message.to);
            ref.$handleError(<ErrorMessage>message);
            break;
        case MessageType.event:
            ref = Scenario.findReference(message.to);
            ref.$handleEvent(<EventMessage>message);
            break;
        default:
    }
}


