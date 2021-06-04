import * as VueRouter from 'vue-router';

import WhatRec from './views/whatrec.vue';
import ScriptView from './views/script-view.vue';

const routes = [
  {
      path: '/',
      redirect: '/whatrec/*/'
  },
  {
      name: 'whatrec',
      path: '/whatrec/:pv_glob?/:selected_records?',
      component: WhatRec,
      props: true
  },
  {
      name: 'file',
      path: '/file/:filename/:line',
      component: ScriptView,
      props: true
  },
]

export const router = VueRouter.createRouter({
  history: VueRouter.createWebHistory(),
  routes: routes,
})