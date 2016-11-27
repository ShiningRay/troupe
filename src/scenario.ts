import { Stage } from './stage';
import { Appearance, Reference } from './appearance';
import {MessageDispatcher, MessageRouter} from './dispatcher'

export class Scenario {
    readonly stage: Stage=Stage.current;
    router: MessageRouter;
    dispatcher: MessageDispatcher; 
    
    static readonly current:Scenario = new Scenario();

    sendMessage(message){
        var stage = Stage.find(message.to);
    }

    static sendMessage(message){
        this.current.sendMessage(message)
    }

    static findAppearance(id):Appearance{
        return 
    }

    static findReference(id):Reference{
        return
    }
}

