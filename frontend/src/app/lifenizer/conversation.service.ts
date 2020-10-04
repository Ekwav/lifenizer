import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, of } from 'rxjs';
import { map, catchError } from 'rxjs/operators';
import { SearchFieldResult } from 'ngx-mat-search-field';

@Injectable({
  providedIn: 'root'
})
export class ConversationService {

  constructor(private http: HttpClient) { }

  getConversations(search: string, size: number, skip: number): import("rxjs").Observable<import("ngx-mat-search-field").SearchFieldResult> {
    const page = Math.round(skip / size) + 1;
    return this.http
      .get(`https://rickandmortyapi.com/api/character/?name=${search.toLowerCase()}&page=${page}`)
      .pipe(
        map((data: any) => {
          let count = 1;
          if (page === 1 && data.info && data.info.pages) {
            count = Number(data.info.count);
          }
          return {
            info: {
              count: count
            },
            items: data.results.map((item: any) => {
              return {
                title: item.species ? `${item.name}|${item.species}` : item.name,
                value: item.id
              };
            })
          };
        }),
        catchError((err: any) => {
          return of({
            info: {
              count: 0
            },
            items: []
          });
        })
      );
  }

}
