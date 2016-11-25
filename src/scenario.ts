import {Stage} from './stage'

import {MessageDispatcher, MessageRouter} from './dispatcher'

export class Scenario {
    readonly stage: Stage=Stage.current;
    router: MessageRouter;
    dispatcher: MessageDispatcher; 
    static readonly current:Scenario = new Scenario();

    sendMessage(message){

    }

    static sendMessage(message){
        this.current.sendMessage(message)
    }
}

