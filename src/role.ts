import { AbstractActor, Actor } from './actor';
import _ = require('lodash')
import eval2 = require('eval2')
import {inherits} from 'util'

const ActorTemplate = `
(function(inherits, AbstractActor){
    var actorClass = function(){
        AbstractActor.call(this);
    }
    inherits(actorClass, AbstractActor);
    <% _.each(trait, (method, name) => {%>
    actorClass.prototype.<%= name %> = <%= method %>
    <% } %>    
    return actorClass;
})
`

const ReferenceTemplate = `
(function(inherits, Reference){
    var referenceClass = function(){

    }
    inherits(referenceClass, Reference);
    <% _.each(trait, (method, name) => {%>
    referenceClass.prototype.<%= name %> = <%= method %>
    <% } %>
    return referenceClass;
})
`

const FactoryTemplate = `
`


export class Role {
    static actorClasses:{[key:string]: Function} = {}
    static referenceClasses:{[key:string]: Function}= {}
    static factoryClasses:{[key:string]: Function} = {}

    static getActor(name) {
        return this.actorClasses[name];
    }

    static getReference(name){
        return this.referenceClasses[name];
    }

    static getFactory(name){
        return this.factoryClasses[name]
    }

    static define<Trait>(name, trait:Trait) {
        var role = function () { 
            Actor.apply(this);
        }

        inherits(role, Actor)
        role.prototype = trait;
        role['name'] = name;
        this.actorClasses[name] = role; 
        return role;
    }

    static register(name, actorClass?){
        if(typeof name !== 'string') {
            actorClass = name;
            name = actorClass.name;
        }
    }

    static extends<Trait>(name, parent, trait:Trait){

    }
    static generateReference(methodNames){

    }
}